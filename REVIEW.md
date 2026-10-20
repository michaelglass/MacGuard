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

## Open (not fixed)

- **Fork users auto-update back to upstream.** `Info.plist` `SUFeedURL` points at `shenglong209/MacGuard`, and `SUPublicEDKey` is upstream's key. A build from this fork will offer upstream's release and silently replace these changes. To distribute the fork, change both values and sign the appcast with your own key.
- **Lid-close protection.** `pmset -a disablesleep 1` is a system-wide, persistent setting. If MacGuard crashes or is force-quit, sleep stays disabled until the user notices. On quit, `resetLidCloseProtection` prompts for an administrator password, although its comment says "silent". A privileged helper (`SMAppService`) or a launchd watchdog that resets the setting would be more robust. This needs on-device testing, so it was left unchanged.
- **Force Quit (⌥⌘⎋) / Activity Monitor / `kill`** can still stop the alarm. A user-space app cannot prevent this. A watchdog launch agent that re-raises the alarm when the process dies would close the gap.
- **Bluetooth identity is spoofable.** Classic-BT trusted devices are matched by MAC address (`bluetoothAddress`), and that address can be spoofed with commodity hardware. A connected Classic device whose RSSI is unavailable is treated as −50 dBm (strong, nearby). BLE matching by `CBPeripheral.identifier` is harder to spoof because iPhones use resolvable private addresses. Proximity should be documented as a convenience, not as authentication.
- **Custom sound path** is a free-form path in `UserDefaults`. Pointing it at a missing or silent file degrades the alarm to a system beep. This is low severity: it requires prior access to the user's account.
- **`scripts/setup-certificate.sh`** hard-codes the `.p12` password `macguard` and prints it. The certificate is self-signed for local use, but the script suggests uploading it as a CI secret.
- **CI release workflow** interpolates `${{ … }}` label and input values straight into shell. These values are maintainer-controlled today. Passing them through `env:` would be safer.

## Verification

- `swift build`: clean, with no new warnings (0 compiler warnings before and after).
- `swift test`: 7 tests for `Countdown`, `PIN`, and `AlarmState` (new `MacGuardTests` target). As a positive control, removing the `isASCII` guard makes the PIN tests fail.
- Compile-time check: `m.disarm(OwnerAuthentication(.pin))` from another file is rejected (`initializer is inaccessible due to 'fileprivate' protection level`).
- **Not** exercised on hardware: the ⌘Q block, the overlay auth flow, and Bluetooth behaviour need a signed build with Accessibility permission and real devices.
