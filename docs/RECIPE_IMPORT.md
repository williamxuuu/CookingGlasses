# Import recipes

Open **Import a recipe** on the Sous home screen or in Recipes. Select a photo from the iPhone photo library, or choose **Link** and paste a public HTTPS recipe page or YouTube cooking video. Tap **Break into steps**. Review and edit the title, ingredients, individual instructions, short glasses instructions, and timer minutes. Edit mode removes or reorders steps. **Save to my recipes** saves locally; open Start Recipe to cook a saved import. Long-press its card to delete it.

All sources use the existing Gemini backend address and backend access token in Debug & settings. The importer derives `/v1/recipes/import` from that server's HTTPS origin. The token currently stays in memory and must be re-entered after app launch. Gemini keys remain on the backend.

The photo picker uploads only the selected image after the import button is tapped. The app downsamples to 2048 pixels and re-encodes JPEG without source EXIF/location metadata. Uploads are limited to 3 MiB; the backend does not save them. Recipe webpages use Gemini's URL Context tool, with successful retrieval metadata required for the exact submitted page. An image of a dish alone is insufficient: use the written ingredients and directions.

YouTube watch, Shorts, mobile, embed, and `youtu.be` share links are normalized to one canonical video URL. Channels, playlists without a video, and malformed video IDs are rejected. Timestamp, playlist, and tracking parameters are discarded; the importer reads the whole video. The canonical URL is sent as a Gemini `fileData.fileUri` video part, without URL Context or a separate downloader/transcription service. Gemini is instructed to consider narration, visible actions, and on-screen text, and to flag missing or conflicting information. Video timestamps are not cooking timers. Videos showing several recipes or alternative methods import only the first complete version, identified in the title and review notes, rather than merging alternatives into one cooking sequence. The resulting draft uses the same review, saving, and glasses-step path as photos and webpages.

Only public YouTube videos are supported; private, unlisted, deleted, age/region-restricted videos may be inaccessible. Instagram/TikTok links and login/paywall pages are not supported. An inaccessible video produces an error without a webpage or memory-based fallback. YouTube video input does not return URL Context retrieval metadata; acceptance relies on Gemini processing the supplied video part and producing a valid recipe. Model output still requires review against the original.

Photos/pages use Gemini 3.5 Flash; YouTube uses Gemini 3.6 Flash with `LOW` thinking, verified with the configured API key after 3.5 returned overload errors. Both return a bounded, validated recipe draft. No recipe, an unreadable image, an inaccessible page, truncation, or invalid structured output produces an error. Ambiguous/missing source details appear as review notes when enough information exists to import. Source URLs and notes stay with saved recipes. The importer does not promise extraction accuracy; review quantities, temperatures, order, and durations against the original.

On the phone's cooking screen, swipe the recipe card left for the next step or right for the previous step. Each step is a native slide-style page; long instructions still scroll vertically with the screen. Swiping browses steps without recording completion or changing timers. Use **Mark done** to complete a step and **Start this step's timer** when appropriate. Imported steps do not automatically create new camera-event detectors. Source durations can create timers; zero means no timer, and a time range uses its lower bound as a check reminder while keeping the range in the full instruction. Saved recipes and ongoing sessions use the same recipe model and remain compatible with older saved sessions.

## Backend contract

`POST /v1/recipes/import`, JSON, with the same `Authorization: Bearer ...` token as observations. Send exactly one of:

```json
{"url":"https://example.com/recipe"}
```

or a public YouTube video link, using the same `url` field:

```json
{"url":"https://www.youtube.com/watch?v=yKUui_b7JO0"}
```

```json
{"jpegBase64":"..."}
```

Success returns `title`, `subtitle`, `ingredients`, `steps` (`title`, `instruction`, `glassesInstruction`, `timerSeconds`), `notes`, and nullable `sourceURL`. Limits: 80 ingredients, 40 steps, 24 hours per step timer. Both endpoints share authentication, body-size, rate, and concurrency limits. Photos/pages have a 45-second model deadline; YouTube videos have 90 seconds. The phone allows 110 seconds including transport. Keep Sous open during import; Cancel stops upstream work. Google retrieves the source; the backend never fetches submitted URLs itself. Long videos can exceed the deadline; use a shorter video showing one recipe.

## Validation

- `npm test` in backend: 25 passing tests, including YouTube URL normalization, video-vs-page routing, inaccessible video rejection, deadline/cancellation, input rejection, retrieval evidence, malformed output, authentication, shared rate limiting, and distinct overload/quota errors.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -j 2 --disable-index-store`: 41 passing core tests, including imported recipe validation, ordering, timers, source/review-note/glasses-text retention, and persistence compatibility.
- Signed iPhone build passed.
- Live Gemini checks passed for a public recipe URL and an original test recipe image, including quantities and a 30-second timer. Physical photo-picker/review interaction still needs a device check.
- September 12, 2026: a live YouTube import through the phone's HTTPS backend returned `English-Style Scrambled Eggs`, 4 ingredients, and 4 cooking/glasses steps in 5.3 seconds. The source was [Jamie Oliver's scrambled eggs video](https://www.youtube.com/watch?v=yKUui_b7JO0), supplied as a `youtu.be` share link with a timestamp. The result preserved the canonical source URL, identified the selected first variation in review notes, flagged missing butter/salt quantities, and did not combine the French/American methods into the cooking sequence. HTTPS authentication and malformed-YouTube-link rejection were also checked. Updated app installed and launched on the paired iPhone; an actual phone UI import/review session has not been automated.

References: [Gemini YouTube video input](https://ai.google.dev/gemini-api/docs/generate-content/video-understanding#pass-youtube-urls), [URL Context](https://ai.google.dev/gemini-api/docs/url-context), [structured output](https://ai.google.dev/gemini-api/docs/structured-output).
