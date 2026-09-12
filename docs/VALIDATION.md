# Validation

The implementation is validated at three separate levels. A passing simulator test cannot establish hardware behavior or vision accuracy.

## Current additions · September 12, 2026

- Recipe imports: **41 core tests and 25 backend tests passed**, covering validated drafts, source/review-note/glasses-text retention, timers, persistence compatibility, YouTube routing, retrieval evidence, authentication, bounds, cancellation, and service errors.
- Signed iPhone builds passed for recipe importing and swipe navigation; the updated app was installed on the paired iPhone 17 Pro Max.
- The 14 existing cooking-state tests passed after the swipe-navigation UI change. Native page swipes have not yet been exercised in an automated UI run.
- Live photo and webpage recipe imports passed. A YouTube import through the phone's HTTPS backend returned 4 ingredients and 4 ordered steps in 5.3 seconds, preserved its source link, and identified the selected recipe variation in review notes. See [recipe import validation](RECIPE_IMPORT.md).
- Physical glasses streaming/display remain unconfirmed. A captured SDK log reported an on-glasses developer component at 0.8.0.34.0 below DAT 0.9's required version; its current state needs a fresh device check.

## Initial MVP checks

- Xcode 26.6 simulator and unsigned physical-iPhone builds with real DAT 0.9.0 Core, Camera and Display packages: passed. The final simulator build was repeated after the independent-timer and layout changes.
- Exact-tag DAT adapter/renderer direct typecheck: passed against the distributed 0.9.0 XCFramework interfaces.
- Foundation core behavior and frame-gate tests: **35 passed**, including multiple manual timers, legacy JSON decoding, independent timer edits through undo, pause/resume, bounded processing and local disk recovery.
- Node backend: 14 tests passed, including HTTP request through injected Gemini transport, malformed inputs/model output, auth, body/frame bounds, throttling, timeout and cancellation. Syntax checks passed.
- Initial iPhone UI run passed placement, duplicate suppression, flip and reconnect assertions, then XCUITest failed to terminate the app for the relaunch segment (`Failed to terminate ... :0`). Process recovery remains covered by the core disk round-trip tests. The final UI test focuses on the interactive flow; its result is recorded below.
- Final `CookingFlowTests.testChickenPlacementFlipAndReconnect` on iPhone 15 Pro / iOS 17.5: **passed in 48.247 seconds**. All placement, duplicate rejection, flip, disconnect/reconnect, and second-side timer assertions passed. The iOS 26.5 runtime initially stalled at boot; iOS 17.5 completed the workflow.
- The home, cooking and debug screens were visually inspected using actual simulator screenshots. [Placement screen](screenshots/chicken-placement.png) and [second-side timer after reconnect](screenshots/second-side-timer.png) are saved with this project.

**Total: 50 passing automated tests** (35 core, 14 backend, 1 UI workflow). No application behavior assertion failed in the final UI run. The earlier XCUITest process-termination failure is retained above rather than counted as a verified relaunch.

Local build/test logs and `.xcresult` bundles are in the ignored `build/` directory. The passing UI bundle is `build/UIFlow-final.xcresult`.

## Required physical acceptance

1. Pair Meta Ray-Ban Display in Meta AI, register the app, grant camera permission, and start Watch explicitly.
2. Verify visible cards and Previous/Next/Undo/Dismiss/+1 min callbacks on the glasses; check all quantities and temperatures are readable without font reduction.
3. Observe actual placement and flip with a configured live backend. Confirm the observation represents a transition, not food already sitting in a pan.
4. Repeat a view of stationary chicken. Confirm no second timer is created.
5. Pause/wear-state changes, remove/fold glasses, disconnect Bluetooth, and reconnect. Confirm no blind restart, lost recipe state, lost timers, or stale display.
6. Lock/background the phone, relaunch it after a timer expires, and validate local notification delivery and timer recovery.
7. Measure sustained battery, thermals, latency, upload volume, false positives/negatives, and confidence prompting in representative kitchens.

The signed phone build and live recipe-import checks above do not establish physical glasses behavior or camera-event accuracy. These acceptance checks remain outstanding.
