# MacGuard review: security, simplicity, types

Reviewed at upstream `3121b6a` (v2.0.8). Lenses: security; simplicity;
*make impossible states impossible* (Richard Feldman); *parse, don't validate*
(Alexis King). Fixed items are in the same commit as this file; open items say
why they were left.

## Fixed

### Security

| # | Finding | Fix |
|---|---------|-----|
| S1 | **⌘Q silences the alarm.** `CountdownWindowController.show` switches the app to `.regular` activation policy and activates it, so the app has a frontmost app menu with Quit ⌘Q. Nothing implemented `applicationShouldTerminate`, so anyone at the keyboard could quit during the countdown or the alarm. The menu-bar Quit button had the same effect. | `AppDelegate` now owns `AlarmStateManager` and returns `.terminateCancel` unless idle. The Quit row is disabled while armed. |
| S2 | **Disarm without authentication.** In the armed state, the menu-bar "Disarm" button and the Settings shield button called `disarm()` directly. Triggers are suppressed while a trusted device is "nearby" (3–5 m at the default *Medium* range), so anyone within that radius of the owner could open the menu and disarm with one click. | `disarm(_:)` now requires an `OwnerAuthentication` value, and only `AuthManager` can create one (`fileprivate init`). UI buttons call `requestDisarm()`, which prompts for Touch ID or the password. Proximity-based disarms go through a `private standDown`. Verified that forging the proof from a view fails to compile. |
| S3 | **PIN brute force.** The PIN could be 4 characters, with unlimited attempts and no delay. Ten thousand guesses is feasible. Comparison used `==` (not constant time). | `verifyPIN` allows 3 free attempts, then locks out for 30 s, doubling (60 s, 120 s, …), and compares in constant time. |
| S4 | **Wake disarm ignored the mode rules.** `systemDidWake` disarmed whenever *any* trusted device was nearby. That bypassed "any device away" mode (which should disarm only when *all* devices are back) and the manual-arm rule ("a device must leave before its return can disarm"). Opening the lid was a weaker disarm path than the device-return path. | Both paths now use one rule, `proximityMayDisarm`. |
| S5 | **Bluetooth recovery fails open.** On Bluetooth power-on, every device's proximity is forced to *nearby*, and away transitions are blocked for 15 s, to prevent false auto-arm. Those assumed states were also used for security decisions: suppressing triggers and disarming on wake. | `isTrustedDeviceNearby()` / `areAllDevicesNearby` return false during the cooldown. The assumption still prevents false auto-arm, but it no longer counts as evidence that the owner is present. |
| S6 | **No way to disarm on some Macs.** The overlay showed a Touch ID button only if biometrics were available, and a PIN button only if a PIN was set. On a Mac without Touch ID (or in clamshell mode) with no PIN, the alarm could not be stopped except by a trusted device. | System auth uses `.deviceOwnerAuthentication` (Touch ID, falling back to the login password) and is always offered. |
| S7 | `Sparkle from: "2.0.0"` with `Package.resolved` gitignored. | Minimum raised to 2.6.4 (the fix release for CVE-2025-0509), so a vulnerable resolution is not possible. |

### Impossible states (Feldman)

| Before | After |
|--------|-------|
| `@Published var countdownSeconds: Int` existed in every state, so `idle` with a 2-second countdown was representable. The ring read the *live* `AppSettings.countdownDuration`, so changing that setting mid-countdown broke the ring. | `case triggered(ArmSession, Countdown)`. `Countdown.remaining ∈ 1...total`, and `ticked()` returns `nil` on expiry, so an expired countdown cannot sit in `.triggered`. |
| `private var wasAutoArmed: Bool` was meaningful only while armed, but had to be reset by hand on every path. | `ArmSession.trustedDeviceHasLeft`, carried by every non-idle case and dropped when the state returns to `.idle`. |
| **Arming race:** `arm()` stayed `.idle` for 1 s, then set `.armed` from a delayed block. Disarm or cancel during that second was silently overridden, and a double arm scheduled the block twice. | A new `case arming(ArmSession)` is entered synchronously. The delayed block proceeds only if the state is still `.arming`. The menu shows "Arming… (Cancel)". |
| `trigger()` and `triggerImmediate()` each re-implemented the proximity-suppression rule. | One `proximitySuppressesTrigger` and one `soundAlarm`. |

### Parse, don't validate (King)

| Before | After |
|--------|-------|
| `validatePIN(String) -> Bool`: the caller learns "yes" but holds nothing that proves it. | `verifyPIN -> PINVerification` (`.accepted(OwnerAuthentication)` / `.rejected` / `.lockedOut(until:)` / `.noPINConfigured`). The proof is the only way into `disarm`. |
| PIN setup checked `count in 4...8` and accepted any characters, although the field says "digits". | `struct PIN { init?(_:) }` accepts 4–8 **ASCII** digits. `savePIN` takes a `PIN`, so an unchecked string cannot be stored. Verification deliberately does *not* parse, so existing non-digit PINs keep working. |
| `if duration == 0 { … }` | `Countdown(seconds:)` returns `nil` for an immediate alarm. |

### Simplicity (dead code removed)

- `Views/PINEntryView.swift`. `PINEntryView` and `PINSetupView` were used only by their own previews; the live UI is `PINOverlay` and `PINSetupContainerView`.
- `AlarmState.menuBarIcon` and `.description`; `GlassStateButtonStyle`; `AuthManager.authenticateWithBiometrics` / `authenticateWithAny` (merged into `authenticate`).
- `BluetoothProximityManager.trustedDevice`, `removeTrustedDevice()`, `reloadTrustedDevices()`, and `isBluetoothUnstable` (published but never observed).

### Behaviour changes to know about

- Disarming from the menu or Settings while armed now asks for Touch ID or the password.
- A manual arm is no longer disarmed by opening the lid near a trusted device unless that device has left during the session. This is the same rule the device-return path already followed.
- You cannot quit (or log out or shut down via the app) while armed. Disarm first.
- New PINs must be digits.

## Round 2: correctness by construction

The core is now a pure function, `AlarmMachine.step(state, input, environment) -> (state, [effect])`.
`AlarmStateManager` is a shell: it parses monitor callbacks into `AlarmInput`, reads a typed `AlarmEnvironment`,
and performs the returned `AlarmEffect`s. Every input is parsed at the edge, so the core has no branches for invalid data.

### Security

| # | Finding | Fix |
|---|---------|-----|
| S8 | **Settings could disable the alarm while armed.** Anyone a nearby trusted device let past the trigger could lower the volume, raise the countdown, swap the sound, remove trusted devices or turn off lid protection, all without authentication. That undid S2. | Configuration sections are read-only unless idle. All config windows (PIN, trusted devices, scanner) close on arm. |
| S9 | **PIN change while armed** needed no authentication and no old PIN. | It cannot be opened unless idle, and the state is re-checked at save time. |
| S10 | **Mute and volume keys didn't trigger.** The event tap had no NX_SYSDEFINED (raw type 14), modifier-only presses (`flagsChanged`) or drags. | All are monitored. The tap mask is *derived from* the `IntrusionInput` enum, so the mask and the parser cannot disagree. |
| S11 | **A UPS hid a cable unplug.** `isOnACPower` read the first power source, and a UPS reports "AC". | It now uses `IOPSGetProvidingPowerSourceType`. |
| S12 | **Enrolment bound by advertised name.** The scanner linked a paired device to *any* BLE peripheral advertising the same (attacker-controlled) name. | It binds only when exactly one peripheral uses that name. A Classic device without an address cannot be trusted. |
| S13 | **A disconnected device could vouch for presence.** "Disconnected" was encoded as −100 dBm, so with a custom range at −95…−100 the device stayed "nearby" forever. CoreBluetooth's 127 "no reading" value counted as a very strong signal. | An `Observation` enum (`.signal(RSSI)` / `.connectedWithoutReading` / `.disconnected`) replaces the stand-in numbers, and `RSSI` parses 0/127 into absence at the edge. |
| S15 | **The event log could be cleared while armed**, wiping the record of an intrusion. | Clear goes through `AlarmStateManager.clearActivityLog()` (idle only), and the button is disabled while armed. |
| S14 | **Timers paused while a menu was open.** The countdown, auto-arm, lid-poll and power timers used the default run-loop mode, so holding a menu open froze the countdown. | All run in `.common` mode. |

### Impossible states / parse, don't validate

- `AlarmState.triggered(ArmSession, Countdown, TriggerCause)` and `.alarming(ArmSession, TriggerCause)`: the cause travels with the state, so alerts can say why. Lid close mid-countdown now escalates.
- `TriggerCause` (`.input(IntrusionInput)`, `.powerDisconnected`, `.lidClosed`) and `PowerSource` are parsed at the monitor boundary. The core never sees `CGEventType`, and the `default: "unknown"` branch is gone.
- `TrustedDevice` is persisted identity only (id, name, `Transport`). `Transport` is `.ble | .classic(BluetoothAddress)`, so "Classic without address" cannot be expressed. Six parallel per-device dictionaries became one `[UUID: DeviceTracking]`. The saved JSON format is unchanged.
- `Proximity` is `.unobserved | .nearby | .away`, and unobserved never vouches for presence.
- `CountdownDuration`, `GracePeriod`, `AlarmVolume(clamping:)`, and `ProximityDistance.thresholds(customDetectionRange:)` (total, with no placeholder thresholds for `.custom`) are all parsed from UserDefaults. `.custom` sound without a file parses to the default.
- `PINThrottle` is a pure value with an injected clock.
- A single definition of "nearby": both device lists used to recompute it from `lastRSSI >= awayThreshold`, which disagreed with the hysteresis, debounce and cooldown.

### Performance

- The activity log rewrote up to 500 entries as pretty-printed JSON on the main thread for *every* line, and Bluetooth logs on most 0.5 s polls. Writes are now coalesced (≤1 per 2 s, compact) and flushed on quit.
- Volume enforcement compiled and ran two AppleScripts every 0.3 s on the main thread while alarming. It now uses CoreAudio (main element, or channels 1/2 on built-in speakers).
- **Bug:** every disarm set the system volume to 50%, even if the alarm never played (`originalVolume` defaulted to 0.5). That value is now optional.
- Runtime readings no longer mutate the published `trustedDevices` array on each poll, which was re-rendering every open view twice a second.

### Simplicity

- Eight copies of a private `log` helper, plus inline `Task { @MainActor … }` wrappers, became one `logActivity(_:_:)`.

### Tests

There are 120 tests in three layers:

| Layer | What it proves | Line coverage |
|---|---|---|
| Pure core: `AlarmMachine`, `AlarmState`, `ProximityTracker`, parsers (including `PlayableSound`), `PINThrottle`, `Alert`, notifier values | every transition and rule, including regressions for S4, the arming race and the suppression modes | 85–100% |
| Seam: the real `AlarmRuntime` (machine + effect interpreter + timers) against a recording `AlarmHardware` and a manual clock | effects reach the right I/O; feedback loops close; stale timers can't fire after stand-down; exit-delay re-arm | 86% |
| Shell: IOKit, CoreBluetooth, CoreAudio, AVFoundation, keychain, AppleScript, SwiftUI views | thin adapters; verified on hardware only | low or none |

Mutation checks:
- Each of these makes tests fail: removing the manual-arm guard, the suppression mode check or the BT-stability guard; wiring `startSystemMonitors` to `stopMonitors`; dropping the exit-delay cancel; never cancelling the countdown timer; letting webhooks accept `http`; ignoring the USB trigger setting; restoring the −100 dBm "disconnected" sentinel; accepting any file as a `PlayableSound`.
- The marker-clear mutation fails 4 tests.

## Round 3: features (all approved; defaults chosen as noted)

| Feature | Default | Notes |
|---|---|---|
| **Pluggable notifications**: Notification Center, Mail, Messages, Shortcuts, Webhook | all **off** (opt-in) | A channel can't be enabled until its recipient parses (`EmailAddress`, phone/Apple ID, Shortcut name, **https-only** `WebhookURL`). Alerts are a pure function of `AlarmEvent`. Delivery runs concurrently off the main actor, and one failing channel never affects another. Mail and Messages pass values as `osascript` *arguments*, never interpolated into the script. Shortcuts is the bridge to anything else (Pushover, Telegram, HomeKit). Each channel has a "Send test" button. |
| **Intruder photo** | **off** | One photo per arm session, taken at countdown start (or when the alarm sounds if there's no countdown). The newest 50 are kept in `~/Library/Application Support/MacGuard/Intruders/` and attached to notifications. Camera permission is requested only when the setting is turned on. |
| **Tamper watchdog** | **on** | Arming writes a marker file. A headless `--watchdog` launchd agent (`SMAppService.agent`, KeepAlive) relaunches the app if it dies while armed, and it comes back sounding (`TriggerCause.tamper`). A single-instance guard prevents duplicates. The launch decision is a pure, tested function. |
| **USB attach trigger** | **on** | Devices already attached at arm time are drained and don't fire. |
| **Network change trigger** | **off** | Fires when a Wi-Fi or wired link is lost or changes. The first reading is the baseline. Switching Wi-Fi networks on the same interface is not detected (that would need CoreWLAN). |
| **Auto-arm on screen lock** | **off** | Arms with manual-arm semantics: a device must leave before its return can disarm. |
| **Exit delay** | **1 s** (as before) | 1 / 5 / 10 / 30 s. The menu shows the remaining time. |

Packaging: verified locally that `create-dmg.sh` builds a bundle with `Contents/Library/LaunchAgents/…watchdog.plist`, a `BundleProgram` that resolves, camera and Apple Events usage strings, and `codesign --verify --deep --strict` passing. `release.yml` makes the same additions.

## Round 4: loose ends

- **Custom alarm sound is parsed.** `PlayableSound` (opens in `AVAudioPlayer`, non-zero length) is checked when a file is picked and when the setting is read. An unplayable pick is rejected. A custom file that was later moved, deleted or corrupted falls back to the bundled sound instead of a system beep: arming logs it and Settings shows a warning. A file that opens but is silent is still accepted.
- **`scripts/setup-certificate.sh`:**
  - The `.p12` password is random per run and never printed. It is saved to `~/.macguard-signing/macguard-signing.p12.password`.
  - The export directory is owner-only (700, files 600); previously the files were world-readable.
  - The password reaches `openssl` through the environment. `security import -P` still takes it as an argument.
  - The temp directory holding the private key is removed on failure too.
  - `-legacy` is passed only to OpenSSL 3. macOS's LibreSSL rejects it, so the script previously failed at the export step on a stock Mac.

- **Local builds were always offered an older release.** `create-dmg.sh` built the bundle version by deleting dots (2.0.8 → `208`), while `release.yml` and the appcast use MAJOR×1000 + MINOR×100 + PATCH (`2008`). Sparkle orders by that number, so every local build saw upstream's older release as an update. `create-dmg.sh` now uses the release formula and drops any `-suffix`. (The formula itself collides from minor version 10 on: 2.10.0 = 3.0.0.)

## Open (not fixed)

- **Tamper relaunch saves the wrong "original" audio state.** The alarm switches output to the built-in speaker and raises the volume. A `kill -9` skips the restore, and the relaunched instance then saves the alarm's speaker and volume as the originals, so disarming "restores" those. Fix: persist the pre-alarm device and volume in the armed marker. Found while planning on-device tests; not verified.

- **Fork users auto-update back to upstream.** `Info.plist` `SUFeedURL` points at `shenglong209/MacGuard`, and `SUPublicEDKey` is upstream's key. A build from this fork will offer upstream's release and silently replace these changes. To distribute the fork, change both values and sign the appcast with your own key.
- **Lid-close protection.** `pmset -a disablesleep 1` is a system-wide, persistent setting. If MacGuard crashes or is force-quit, sleep stays disabled until the user notices. On quit, `resetLidCloseProtection` prompts for an administrator password, although its comment says "silent". A privileged helper (`SMAppService`) or a launchd watchdog that resets the setting would be more robust. This needs on-device testing, so it was left unchanged.
- **Killing both the app and its watchdog** stops protection until launchd restarts the watchdog (about 10–15 s). A user-space design can't do better without a privileged daemon.
- **Hardened runtime is not enabled** (`codesign` never passes `--options runtime` or the entitlements file). If it is turned on, add the camera and Apple Events entitlements to `MacGuard.entitlements` and pass it.
- **Likely blind spot after "lock on arm".** Secure input (the lock-screen password field) stops keystrokes reaching other processes' event taps ([TN2150](https://developer.apple.com/library/mac/technotes/tn2150/_index.html)). Whether pointer events still arrive needs testing on hardware. If they don't, only the lid, power, USB and Bluetooth triggers protect a locked Mac.
- **Bluetooth identity is spoofable.** Classic-BT trusted devices are matched by MAC address (`bluetoothAddress`), and that address can be spoofed with commodity hardware. A connected Classic device whose RSSI is unavailable is treated as −50 dBm (strong, nearby). BLE matching by `CBPeripheral.identifier` is harder to spoof because iPhones use resolvable private addresses. Proximity should be documented as a convenience, not as authentication.
- **CI release workflow** interpolates `${{ … }}` label and input values straight into shell. These values are maintainer-controlled today. Passing them through `env:` would be safer.

## Verification

- `swift build`: clean, with no new compiler warnings.
- `swift test`: 120 tests (see Tests above for the layers and mutation checks).
- Compile-time check: `m.disarm(OwnerAuthentication(.pin))` from another file is rejected (`initializer is inaccessible due to 'fileprivate' protection level`).
- Packaging: `create-dmg.sh` builds a bundle that passes `codesign --verify --deep --strict`.
- `setup-certificate.sh`: `bash -n` and `shellcheck` pass. The export step was exercised against macOS's LibreSSL. The full script was not run, because it writes to the login keychain.

## Hardware verification checklist (not done here)

None of these have been run on a real machine. They need a signed build on a real Mac:
1. The ⌘Q block while the overlay is up.
2. The Touch ID / password prompt above the overlay.
3. The PIN lockout message.
4. Pointer and keyboard events still trigger after "lock on arm" (the secure input question).
5. Media keys, USB plug-in, cable unplug with and without a UPS, network-cable pull.
6. The watchdog:
   - registration, and Login Items approval
   - `kill -9` while armed: the alarm returns in about 2–4 s
   - a clean idle quit leaves no relaunch
   - no duplicate menu-bar icons at login
7. The camera:
   - the permission prompt and the denied state
   - exposure after the 1 s warm-up
   - the camera light turns off after each capture
8. Notifications: a real send through each channel, and the Apple Events prompts for Mail and Messages.
9. BLE: identifier rotation for devices that aren't bonded (possible false "away").
