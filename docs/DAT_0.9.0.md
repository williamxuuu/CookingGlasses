# Meta Wearables DAT 0.9.0 integration

This app targets iOS **17.2 or newer** and pins `facebook/meta-wearables-dat-ios` to **exactly 0.9.0**, tag commit `9b1b83d791dfebff7afd452e924a256819094b64`. The tag distributes binary XCFrameworks. Its embedded public Swift interfaces, rather than older camera snippets, are the source of truth for the adapter.

The tag's frameworks were produced with Swift 6.3.3. The local Xcode 26.6 toolchain reports the same compiler. Use the full Xcode installation (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if the machine defaults to Command Line Tools).

## Verified API surface

The app links `MWDATCore`, `MWDATCamera`, and `MWDATDisplay` from the [tagged package](https://github.com/facebook/meta-wearables-dat-ios/blob/0.9.0/Package.swift).

| Purpose | Exact Swift API used in 0.9.0 |
| --- | --- |
| Initialize once | `try Wearables.configure()` |
| Shared SDK interface | `Wearables.shared` (non-optional `any WearablesInterface`) |
| Register | `try await wearables.startRegistration()` |
| App callback | `try await wearables.handleUrl(url)` returning `Bool` |
| Observe registration/devices | `registrationStateStream()`, `devicesStream()`, `deviceForIdentifier(_:)` |
| Choose display glasses | `AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })` |
| Create session | `try wearables.createSession(deviceSelector: selector)` |
| Start/stop session | `try session.start()`, `session.stop()` (both synchronous) |
| Observe lifecycle | `session.stateStream()`, `session.errorStream()` |
| Camera permission | `try await wearables.checkPermissionStatus(.camera)`, then `requestPermission(.camera)` if needed |
| Add camera | `try session.addCamera(config: configuration)` returning `Camera?` |
| Camera configuration | `StreamConfiguration(videoCodec: .raw, resolution: .low, frameRate: 7)`; frame rate parameter is `UInt` |
| Get/start stream | `camera.stream`, `stream.start()` (synchronous) |
| Frames and errors | `stream.videoFramePublisher.listen`, `stream.statePublisher.listen`, `stream.errorPublisher.listen` |
| Decode frame | `VideoFrame.makeUIImage()` or `VideoFrame.sampleBuffer` |
| Detach camera | `camera.stop()` (synchronous, stops child stream too) |
| Add/start display | `try session.addDisplay()` returning `Display`, then `display.start()` |
| Push one root card | `try await display.send(FlexBox(...))` |
| Display lifecycle | `display.statePublisher.listen`, `display.stop()` |
| Listener lifetime | Retain returned `any AnyListenerToken`; `await token.cancel()` on teardown |

Public interface sources: [Core](https://github.com/facebook/meta-wearables-dat-ios/blob/0.9.0/MWDATCore.xcframework/ios-arm64/MWDATCore.framework/Modules/MWDATCore.swiftmodule/arm64-apple-ios.swiftinterface), [Camera](https://github.com/facebook/meta-wearables-dat-ios/blob/0.9.0/MWDATCamera.xcframework/ios-arm64/MWDATCamera.framework/Modules/MWDATCamera.swiftmodule/arm64-apple-ios.swiftinterface), [Display](https://github.com/facebook/meta-wearables-dat-ios/blob/0.9.0/MWDATDisplay.xcframework/ios-arm64/MWDATDisplay.framework/Modules/MWDATDisplay.swiftmodule/arm64-apple-ios.swiftinterface).

Do not use `StreamSession`, `StreamSessionConfig`, or `DeviceSession.addStream(config:)` from older examples. In particular, `addStream` was removed in 0.9.0. See the [0.9.0 changelog](https://github.com/facebook/meta-wearables-dat-ios/blob/0.9.0/CHANGELOG.md).

## Display behavior

DAT 0.9.0 **does support rendering on Meta Ray-Ban Display glasses**. `MWDATDisplay` includes `FlexBox`, native `Text` styles, `Button` callbacks, and `ButtonGroup`. This is a real adapter, while the app's mock mode and phone card preview allow development without glasses.

`DATGlassesRenderer` uses native heading/body/meta styles and short recipe instructions. Previous and Next dispatch navigation offsets only. Undo, timer dismissal, and adding one minute are separate typed callbacks. Expiration asks the cook to check food; the display never claims a timer proves food safety. A new `display.send` replaces the current card, so the adapter serializes sends and coalesces pending timer updates.

## Hardware setup

1. Install Meta AI on the physical iPhone and pair compatible Meta Ray-Ban Display glasses. Enable Developer Mode for that pair and apply its settings to the glasses. Check Meta's [version dependencies](https://wearables.developer.meta.com/docs/develop/dat/version-dependencies/) for compatible companion-app, firmware, and DAT app versions.
2. In Xcode, select your signing team and use a unique bundle identifier. The app's URL scheme must match `MWDAT.AppLinkURLScheme` (`cookingglasses` versus `cookingglasses://`). `LSApplicationQueriesSchemes` must include `fb-viewapp` for Meta AI handoff.
3. Supply the Meta project values when using a registered release channel: `MWDAT.MetaAppID`, `ClientToken`, and `TeamID` (the Apple signing team). `MetaAppID = 0` is the developer-mode setup described by Meta. These are Meta registration configuration, not the Gemini server key. See [Meta's setup guidance](https://github.com/facebook/meta-wearables-dat-ios/blob/main/.github/copilot-instructions.md) and [integration guide](https://wearables.developer.meta.com/docs/build-integration-ios).
4. Keep `UISupportedExternalAccessoryProtocols = [com.meta.ar.wearable]`, Bluetooth usage text, and the background modes required by the selected transport. Meta's display guidance specifies `external-accessory` and `bluetooth-central`. The MVP uses Bluetooth transport. Wi-Fi transport requires its additional local network/Bonjour configuration and must be validated separately.
5. Launch the app, select real Meta glasses mode, connect, finish registration in Meta AI, and grant the glasses camera permission when starting Cooking Watch. Wear the glasses during session startup.

The obsolete `MWDAT.DAMEnabled` switch is ignored in 0.9.0 because the DAT App Model is always enabled. Do not try to restore the old camera lifecycle with it. The developer portal may require login; no app IDs, signing entitlements, companion registrations, or physical-device permissions are fabricated by this project.

## Pause, reconnect, and privacy

An active session must reach `.started` before capabilities are attached. While `.paused`, the app preserves the same session and camera, keeps timers in the phone store, and displays “Cooking Watch paused — timers still running.” It does **not** repeatedly call `start` to override the SDK's wear state or system experience.

After the same session returns to `.started`, the current card is resent; the stream's lifecycle determines whether monitoring is active. In 0.9.0 both session async streams terminate after `.stopped`, so that object is discarded. After a terminal disconnection, the cook reconnects and explicitly starts Watch again. The new display receives the current phone state rather than rebuilding recipe/timer state.

Camera callbacks are capped at two image conversions per second before the app's configurable frame processor applies stricter normal/action/timer rates. Only an explicitly started Watch receives frames. Camera frames are not written to disk by this adapter. Stopping Watch detaches the camera while allowing the display session to keep showing instructions and timers.

## Physical acceptance checks still required

These checks require real paired Meta Display glasses; compilation and phone mocks cannot certify them:

- Registration URL handoff and camera permission round trip.
- Real frames reaching local change detection and the configured backend.
- Card layout, native button focus/captouch interaction, text wrapping, and legibility at the hardware's actual display size.
- Chicken placement → one five-minute timer; repeat view → no duplicate; flip → one four-minute timer.
- SDK pause/resume without repeated camera restarts; terminal reconnect creates a new session and resynchronizes the card.
- Bluetooth range loss, glasses folded/removed, thermal/battery errors, Meta AI app interruption, and background/foreground transitions.
- Actual transport and firmware compatibility, sustained power use, timer alerts while the phone is locked, and acceptable classification latency/accuracy.

The MVP can demonstrate the deterministic flow in mock mode before these hardware checks. A successful build does not establish camera accuracy or hardware compatibility.
