# Water, Boil & Spoon Test

One recipe step, three ordered camera checkpoints: water added to a pot, a rolling boil, then a wooden spoon inserted. There is no cooking timer. Only the next checkpoint is requested from Gemini, and the step completes after all three.

## Run

1. Open Sous → Start Recipe → **Water, Boil & Spoon Test** → Start cooking.
2. In Debug & settings select physical Meta glasses, disable **Mock AI Events**, configure the HTTPS backend/token and connect. Complete any Meta registration/camera permission prompts.
3. Start Cooking Watch before pouring. Keep the pot interior visible. Sous keeps the foreground phone awake during Watch; manually locking it or switching apps still stops capture.
4. Add water. Wait for its checkmark, then heat to a rolling boil. Wait for the second checkmark, then visibly insert a wooden spoon.
5. The screen shows checkpoint timestamps and the latest request duration. Undo restores the previous checkpoint; Reset test checkpoints starts over.

For a camera-only trial, do not use Mark done or simulated events. Human confirmations of lower-confidence detections are not independent evidence of model accuracy.

## Detection

The adapter requests 7 fps and converts at most 2 fps. This test samples every 0.5 seconds and retains up to eight JPEGs from the last five seconds. Checks require at least eight seconds between request starts, with one request in flight. For this test, an eight-second periodic fallback also checks quiet scenes; it prevents the 32x32 motion threshold from indefinitely suppressing a view of boiling water. Other recipes retain the existing motion-only gate.

Water filling and spoon insertion require visible transitions. A rolling boil requires sustained vigorous bubbling across the surface in multiple frames. Steam, small edge bubbles, stirring, obscured water, metal utensils and a spoon already resting in the pot must not establish the corresponding events. The boiling timestamp is the earliest clear evidence in the supplied window, not a claim about an earlier unseen onset or a measured temperature.

Checkpoint evidence persists with recipe state; camera images are not saved. Debug console output contains event labels, estimated timestamps, confidence, request duration and acceptance status, without images or credentials.

Debug builds accept `SOUS_LIVE_TEST_SETUP=1`, `SOUS_BACKEND_URL` and `SOUS_BACKEND_TOKEN` in the process launch environment. This selects physical glasses and disables simulated AI without compiling or persisting the token. It does not start capture or replace the current recipe.

## Validation

- 45 core tests and 26 backend tests passed, including ordered checkpoints, persistence, undo/reset, one-current-event request schemas and periodic sampling/backpressure.
- Signed iPhone build succeeded and was installed on the paired iPhone 17 Pro Max.
- A live HTTPS request using two generated blank JPEGs returned `uncertain` in 5.622 seconds. This validates connectivity and Gemini availability, not cooking recognition.
- Both simulator UI attempts were blocked during app/test-runner installation by insufficient Mac storage. They do not establish UI correctness. Temporary simulator build products were removed afterward; the failed-run logs and result bundles remain under `build/`.
- The final signed build includes foreground keep-awake behavior and was installed and launched with physical glasses selected, mock AI off and runtime backend credentials. The Mac console connection later disconnected; this is not evidence of a successful glasses stream.
- Physical water/boil/spoon recognition remains to be tested by the wearer.

## Recorded trial diagnosis

The supplied `IMG_2925.MP4` visibly shows water entering the pot. Eight selected frames around 16–19.5 seconds were replayed through the observation classifier. The existing 3.5 Flash service returned busy through the live endpoint, and a subsequent direct request timed out at 15 seconds. The same image sequence and observation prompt on 3.6 Flash returned `water_added_to_pot`, confidence 0.95, in 1.812 seconds. Live observations now use 3.6 Flash; photo/web import model selection is unchanged.

This replay is not a reconstruction of the original live request: live image payloads were not saved, and the recording includes a display overlay. We cannot establish which frames the original request contained or its exact failure. There is also a known sampling limitation: `finishRequest()` clears images collected during inference, and the eight-second cooldown can leave gaps between the short submitted windows. The model change addresses the observed service failures, but does not remove those sampling gaps.

### Intermittent vision failure diagnosis (September 13)
- Low-confidence observations and `uncertain` are valid successful responses; they do not produce a service error. A 60% definite event requires confirmation.
- The former iOS catch hid all transport/backend failures behind “Vision unavailable.” The app now distinguishes network failures, HTTP access errors, model timeout/busy/rate-limit errors, and invalid observations. Debug retains the last failure with a time.
- Backend diagnostics record only time, HTTP status, safe error code, and request duration. They do not retain frames, credentials, recipe text, or raw model output.
- The previously configured quick tunnel failed DNS and logged “Unauthorized: Tunnel not found.” Replacement tunnel recovery was also unsuccessful at public DNS verification. This confirms a current infrastructure fault, but cannot identify every earlier request's cause because earlier errors were discarded.
- Direct local-backend replay of the supplied pouring clip returned HTTP 200, water_added_to_pot, confidence 0.95, in 2.2 seconds. This bypasses the failed public tunnel and does not establish that phone streaming is restored.
- Validation: 47 Swift core tests and 27 backend tests passed; signed iPhone build succeeded and installed. Public tunnel connectivity remains unresolved.
