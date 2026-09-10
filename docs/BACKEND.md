# Gemini observation backend

The implementation is in `backend/` and uses only Node.js built-ins. The server owns model credentials and translates the app's observation request into a Gemini multimodal classification request. It returns evidence; the app's recipe state machine decides whether the evidence can complete a step or start a timer.

## HTTP contract

`POST /v1/cooking/observe`

Headers:

```text
Authorization: Bearer <runtime backend token>
Content-Type: application/json
```

Request example (replace the illustrative JPEG values and timestamps with a recent sequence):

```json
{
  "recipe": {
    "id": "pan-seared-chicken",
    "title": "Pan-seared chicken"
  },
  "step": {
    "id": "add-chicken",
    "title": "Add the chicken",
    "fullInstruction": "Carefully place the chicken in the pan."
  },
  "expectedEvents": ["chicken_added_to_pan"],
  "frames": [
    { "timestamp": 1800000000.0, "jpegBase64": "<base64 JPEG before the action>" },
    { "timestamp": 1800000001.0, "jpegBase64": "<base64 JPEG during the action>" },
    { "timestamp": 1800000002.0, "jpegBase64": "<base64 JPEG after the action>" }
  ]
}
```

Successful response:

```json
{
  "event": "chicken_added_to_pan",
  "ingredient": "chicken",
  "confidence": 0.92,
  "estimatedEventTimestamp": 1800000001.0
}
```

`ingredient` is optional and omitted when unknown; it is never `null`. All timestamps are floating-point Unix seconds, matching Swift's `.secondsSince1970` JSON date strategy. Confidence is a finite number in `[0, 1]`. It is a model estimate, so the client still enforces its confidence threshold, current step, prerequisites, freshness, session revision, and confirmation requirements.

Known events:

| Event | Meaning |
| --- | --- |
| `chicken_added_to_pan` | Chicken transitions into the pan |
| `chicken_flipped` | Chicken is visibly turned |
| `chicken_removed_from_pan` | Chicken transitions out of the pan |
| `pot_placed_on_stove` | A pot is placed on the stove |
| `pasta_added_to_water` | Pasta enters the cooking water |
| `ingredient_added` | An ingredient is visibly added |
| `uncertain` | Possible relevant action with insufficient evidence |
| `no_relevant_event` | No relevant transition is observed |

The response event must appear in the request's `expectedEvents`, or be `uncertain` or `no_relevant_event`. An empty `expectedEvents` array is allowed and permits only those two non-action results. Unknown enums and duplicate expected events are rejected before a model call. Additional fields are rejected in requests and observations to keep the transport contract narrow.

## Boundaries

| Boundary | Default |
| --- | --- |
| JPEG frames per request | 2–8 |
| JPEG bytes per frame | At most 512 KiB before base64 encoding |
| JPEG dimensions | At most 1280 pixels in either dimension |
| Whole request body | At most 6 MiB, including base64 and JSON |
| Frame ordering | Strictly increasing timestamps |
| Sequence duration | At most 15 seconds |
| Frame freshness | No older than 60 seconds; at most 5 seconds in the future |
| Event time | Inside the first-to-last frame interval, inclusive |
| Body upload deadline | 10 seconds |
| Upstream deadline | 15 seconds by default, including response body reading |
| Upstream response body | At most 64 KiB |
| Concurrent authenticated bodies/model calls | 2 per server process |
| Authenticated attempts | 30 per rolling minute per server process |

Base64 must be canonical, without a data-URL prefix or whitespace. The server checks JPEG start/end markers, segment lengths and dimension headers; it does not fully decode image pixels. Metadata lengths are bounded: IDs 100 characters, titles 200, instructions 2000, and returned ingredient 80. Image data stays in request-local memory and is forwarded inline. The server does not write frame files, store sessions, create caches, or log request payloads, headers, frames, or model output.

The rate guard is shared across clients using the single MVP token. It intentionally applies before parsing authenticated requests. Invalid authenticated attempts use this budget; unauthenticated requests never reach Gemini. Concurrency includes incoming bodies to keep memory bounded. Requests rejected for concurrency return immediately and are not queued. These guards reset on process restart and do not coordinate multiple server instances. A public multi-user deployment needs real user authentication and a shared quota store at its gateway.

## Errors and cancellation

Errors use a stable envelope:

```json
{
  "error": {
    "code": "model_timeout",
    "message": "Observation timed out. Try again or continue manually."
  }
}
```

| Status | Typical codes | Client response |
| --- | --- | --- |
| 400 | `invalid_request` | Correct the sequence or request shape |
| 401 | `unauthorized` | Enter the configured backend token |
| 404 / 405 | `not_found` / `method_not_allowed` | Check endpoint and method |
| 408 | `request_timeout` | Wait for a fresh sequence |
| 413 / 415 | `request_too_large` / `unsupported_media_type` | Reduce frame size; send plain JSON |
| 429 | `rate_limited` / `busy` | Honor `Retry-After`; keep manual controls usable |
| 502 | `model_unavailable` / `invalid_model_response` | Discard the observation and continue manually |
| 503 | `model_unavailable` | Honor `Retry-After`; provider is temporarily unavailable |
| 504 | `model_timeout` | Discard the observation and wait for a fresh sequence |
| 500 | `internal_error` | Discard the observation and continue manually |

Malformed HTTP itself may be rejected by Node before the JSON handler. Every application response has `Cache-Control: no-store`. Upstream exception text and response bodies never reach the client. Safety-blocked responses, truncated output, non-JSON output, unknown fields, invalid confidence, unrelated events, and timestamps outside the supplied sequence fail validation. No error is converted into an invented successful event.

When a client closes its connection during inference, the upstream request is aborted. Server shutdown also aborts in-flight observations. There are no automatic upstream retries, avoiding duplicate cost and stale evidence. A canceled request has no usable result; the app must independently discard late responses after navigation, correction, recipe changes, or monitoring stops.

## Gemini integration

The endpoint is `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent`. The API key is sent in the `x-goog-api-key` header, never in the URL or iOS bundle. Google lists `gemini-3.5-flash` as accepting images and supporting structured output. [Gemini 3.5 Flash model documentation](https://ai.google.dev/gemini-api/docs/models/gemini-3.5-flash)

Each request has one user content object containing recipe context, then alternating timestamp text and JPEG `inlineData` parts in chronological order. `generationConfig.responseMimeType` is `application/json`; `responseJsonSchema` limits the event enum, confidence, and timestamp range. `candidateCount` is 1 and output is capped at 1024 tokens. `store: false` disables request logging through the API's per-request logging control. No file upload or conversational state is created. [GenerateContent REST API](https://ai.google.dev/api/generate-content)

The system instruction asks the model to identify a visible transition across frames, treat recipe and image text as untrusted data, avoid guessing from recipe order, and return uncertainty when evidence is weak. It requests no navigation, timer decisions or food-safety judgments. The model is configured with `MINIMAL` thinking for this bounded classification task; the model's supported levels include minimal. [Gemini thinking documentation](https://ai.google.dev/gemini-api/docs/thinking)

Structured output controls shape, so the server also validates semantic constraints before returning a result. Multiple-image prompting is supported, but event recognition accuracy still requires testing on representative cooking sequences. [Structured output documentation](https://ai.google.dev/gemini-api/docs/structured-output), [Image understanding documentation](https://ai.google.dev/gemini-api/docs/image-understanding)

The no-storage behavior above describes this server and its explicit API logging setting. Frames are still transmitted to Google for inference, and provider processing, abuse monitoring and account-specific data terms remain governed by the configured Gemini service. Obtain camera-processing consent in the app before monitoring. [Gemini API terms](https://ai.google.dev/gemini-api/terms)

## Setup and tests

Follow [backend/README.md](../backend/README.md) to configure `.env` and start the server. The `.env.example` file contains no credentials. `GEMINI_API_KEY` and `COOKING_API_TOKEN` are required; startup fails when either is absent or the backend token is too short. Rotate the backend token by changing the server environment and updating the app Settings value.

Optional environment values are `HOST`, `PORT`, `MAX_REQUESTS_PER_MINUTE`, `MAX_CONCURRENT_REQUESTS`, and `GEMINI_TIMEOUT_MS`. The checked-in defaults are appropriate for a local single-user MVP. For a physical iPhone use an HTTPS endpoint with a valid certificate and forward to the server's HTTP listener; do not put model credentials into an app configuration file. Keep request-body and authorization logging disabled in any proxy or hosting platform too.

Run `npm test` and `npm run check` from `backend/`. The test suite uses loopback HTTP requests, a tiny generated JPEG and injected fake Gemini responses. It checks request construction, schema/enum/confidence/time validation, authentication, declared/chunked body limits, upstream failure handling, timeout aborts, client disconnects, quotas and concurrency release. No test calls the Gemini service or needs an API key. Hardware behavior, recognition accuracy and live provider access are outside these automated checks.
