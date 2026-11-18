# Manual QA guide

Hardware checks for everything this fork changed since upstream v2.0.8, plus the existing features most likely to have broken along the way. The automated tests (`mise check`) cover the logic: the alarm state machine, proximity rules, settings parsing, audio playback, and the lid-close watcher script. What's left needs a real Mac.

Tags: **NEW** is a new feature; **CHANGED** is an existing feature that behaves differently; **REGRESSION** is an existing feature whose code was rewritten and should behave exactly as before.

## Before you start

- **Have an escape hatch.** The alarm plays at full volume, and the overlay disables ⌘-Tab, Force Quit and log out. Set a PIN first (Settings → Security). If you ever get stuck, SSH in from another machine and run:
  ```sh
  rm ~/Library/Application\ Support/MacGuard/armed-session; killall MacGuard
  ```
  Remove the marker first, or the watchdog relaunches the alarm.
- **Set the countdown long** (Settings → Behavior → Countdown duration) while testing, so you have time to disarm.
- **Keep the Event Log open** (Settings → Event Log → View Log). Most steps below say what should appear there.
- **What you'll need:** a trusted phone (and ideally a second device such as a watch or AirPods), a second display, a USB stick, the power adapter, and a second machine for SSH.
- **Useful commands:**
  ```sh
  pmset -g | grep SleepDisabled            # 1 while lid-close protection holds sleep off
  pgrep -lf MacGuard                       # the app and its watchdog (MacGuard --watchdog)
  pgrep -lf 'disablesleep'                 # the root lid-close watcher, when connected
  ```

## 1. Install and permissions (CHANGED: signing)

The build is now signed with your Apple Development certificate and hardened runtime, so macOS may treat it as a new app.

- [ ] Settings → Permissions shows Accessibility and Bluetooth as Granted. If not, grant them; Accessibility may need removing and re-adding under Privacy & Security.
- [ ] Input monitoring works: arm, move the mouse, and the countdown starts. A dead trigger after reinstalling almost always means Accessibility needs re-granting.
- [ ] Camera (if Intruder Photo is on) and Mail/Messages automation (if those channels are on) prompt again or still work.
- [ ] Settings → About → Check for Updates says you're up to date and shows no error. The feed is this fork's `appcast.xml`, which is empty for now.

## 2. FileVault row (NEW)

- [ ] Settings → Permissions shows a FileVault row reading "Disk encrypted" and "On".
- [ ] Optional, if you have a Mac with FileVault off: the row shows the warning "Off: a thief can restart this Mac and read or reset its disk" and an Open Settings button that opens Privacy & Security.

## 3. Arming (REGRESSION)

- [ ] Menu bar → Arm MacGuard: the menu shows "Arming in Ns… (Cancel)", then the icon turns green.
- [ ] Cancel during arming returns to idle.
- [ ] With Behavior → Lock screen when armed on, arming locks the screen.
- [ ] With Exit delay set, triggers during the delay are ignored.
- [ ] The menu bar icon follows the state: outline when idle, grey while arming, green when armed, orange while counting down, red while alarming.

## 4. The overlay covers everything (CHANGED)

Use two or more displays, and put a window on another Space first.

- [ ] Arm, then move the mouse: the countdown overlay appears on **every** display, not just one.
- [ ] Switch Spaces (Ctrl-←/→ or a trackpad swipe): the overlay is on every Space too.
- [ ] Nothing behind the overlay is clickable on any display.
- [ ] Unplug or plug in a display during the countdown: the overlay follows.
- [ ] Kiosk mode: ⌘-Tab does nothing, ⌥⌘Esc doesn't open Force Quit, ⌘Q doesn't quit, ⌘H doesn't hide, the Apple-menu log out is unavailable, and the Dock and menu bar are hidden.
- [ ] After disarming, all of that comes back: ⌘-Tab, Force Quit, the Dock and the menu bar.

## 5. Disarming (REGRESSION)

- [ ] Overlay → Disarm with Touch ID: the Touch ID prompt appears **above** the overlay, and succeeding disarms.
- [ ] Password fallback works the same way.
- [ ] Enter PIN → the right PIN disarms.
- [ ] Wrong PINs: after several, a lockout message appears, and the PIN is refused until it expires.
- [ ] Disarming from the menu (Disarm) needs authentication too.

## 6. Alarm sound and audio restore (CHANGED)

Before arming, set the output to headphones or AirPods and the volume low.

- [ ] Let the countdown run out: the alarm plays from the **Mac's speakers** at full volume, not from the headphones.
- [ ] Disarm: the output returns to the headphones and the volume returns to where it was.
- [ ] Behavior → Alarm Sound: each built-in sound previews when chosen. Choose… with a custom file plays it; an unplayable file shows "can't be played - using the default sound".
- [ ] The Volume setting is respected.

## 7. Proximity (CHANGED: redesigned)

The rule now: **only a trusted device that was away during the armed session can disarm by coming back.** A device that stays nearby never silences or disarms anything. Use two trusted devices if you can (say, phone and watch).

Setup:
- [ ] Trusted Devices → Manage Devices → Add Device finds your phone. The list shows signal strength, already-added devices can't be added twice, and the count reads "N of 10 devices".
- [ ] Detection Distance changes what counts as nearby. "Current signal" updates live.

Scenarios:
- [ ] **Phone left on the desk.** Arm with the phone next to the Mac, walk away **without** it, then touch the trackpad: the countdown runs and the alarm sounds. The phone being nearby must not stop it. The Event Log says "nearby but was here at arming - not disarming".
- [ ] **Walk away and come back.** Arm, walk away **with** the phone until the Event Log says "left proximity" and "may now disarm on return", then come back: it disarms by itself ("Disarmed via trusted device").
- [ ] **Return during the alarm.** Same as above, but trigger the alarm while away, then return: the alarm stops.
- [ ] **Return while asleep.** Walk away with the phone, let the Mac sleep, then come back and wake it: it disarms on wake.
- [ ] **Only the device that left.** Arm with both phone and watch nearby, walk away with only the phone, and trigger: the watch, still nearby, does not disarm. Coming back with the phone does.

Auto-arm (Behavior → Auto-arm when devices leave):
- [ ] Walk away with a trusted device: after the grace period, MacGuard arms itself.
- [ ] Come back within the grace period: auto-arm is cancelled.
- [ ] A device that was never nearby (for example a powered-off watch) doesn't start a grace period.
- [ ] Turn Bluetooth off and on again on the Mac: no false auto-arm in the first 15 seconds.

## 8. Tamper protection (CHANGED)

Settings → "Alarm if MacGuard is force-quit" must be on; it may ask you to allow MacGuard in Login Items.

- [ ] While idle, `pgrep -lf MacGuard` shows the app and `MacGuard --watchdog`.
- [ ] **Kill while armed.** Arm, then from SSH run `killall -9 MacGuard` (only the app, not the watchdog). Within about 2–4 seconds MacGuard relaunches with the alarm sounding and the overlay up.
- [ ] **Audio after a kill.** Repeat with headphones and a low volume set before arming, and kill it while the alarm is already sounding. After the relaunch and a disarm, the output and volume go back to your original settings, not the alarm's.
- [ ] **Departure kept across a kill (NEW).** Arm with the phone nearby, walk away with it until "left proximity" appears, kill MacGuard from SSH, then come back with the phone: it still disarms.
- [ ] **Quit blocked.** While armed, Quit in the menu and ⌘Q do nothing; the Event Log says "Quit blocked - disarm first".
- [ ] **Clean quit.** While idle, Quit: MacGuard stays gone and the watchdog doesn't relaunch it.
- [ ] After a restart and login, there's one menu bar icon, not two.

## 9. Lid-close protection (NEW)

- [ ] Behavior → turn on Lid close alarm: **one** admin prompt appears, saying "MacGuard needs an administrator password to keep the Mac awake when the lid closes while armed." Enter the password, and the row reads "Mac won't sleep when the lid closes while armed".
- [ ] While idle, `pmset -g | grep SleepDisabled` reads 0, and closing the lid sleeps the Mac normally.
- [ ] Arm: `SleepDisabled` reads 1. Close the lid: the alarm sounds immediately, and the Mac stays awake.
- [ ] Disarm: it reads 0 again.
- [ ] Quit MacGuard while idle: it reads 0, and `pgrep -lf disablesleep` shows nothing.
- [ ] Relaunch: **one** prompt again (once per launch is by design).
- [ ] Cancel that prompt: the row shows "Not active: the password prompt was cancelled" with Try again, and Try again prompts again.
- [ ] Turn the setting off: it reads 0 and the watcher exits.
- [ ] **Kill while armed.** Arm with protection on, then `killall -9 MacGuard` from SSH. `SleepDisabled` drops to 0 at once, the watchdog relaunches the alarm, and a new prompt appears. Entering the password brings protection back. This is the accepted gap: cancelling that prompt leaves the session without lid-close protection.
- [ ] Settings are locked while armed, so the toggle can't be turned off then.

## 10. Other triggers (REGRESSION)

For each one, arm, do it, and confirm the countdown starts (or, for power and lid, the alarm sounds at once):

- [ ] Keyboard, including media keys (volume, brightness).
- [ ] Trackpad and mouse movement, clicks, and scrolling.
- [ ] **After "Lock screen when armed".** With the screen locked, does moving the pointer or typing still trigger? Keystrokes may not (the lock screen's secure input blocks them); record what happens either way.
- [ ] Power cable unplugged: the alarm sounds immediately. If you have one, also try a UPS-backed adapter.
- [ ] USB device plugged in (Alarm when a USB device is plugged in).
- [ ] Mac moved or lid angle changed (Alarm when the Mac is moved / Alarm when the lid is moved; try each Motion sensitivity).
- [ ] Network change, such as unplugging Ethernet or switching Wi-Fi (Alarm when the network connection changes).
- [ ] Arm automatically when the screen locks: locking the screen arms MacGuard.
- [ ] **Power button (open question).** While armed, a short press of the power or Touch ID button: does it trigger the alarm? Note the result.
- [ ] Each trigger's toggle, when off, really disables it.

## 11. Notifications and intruder photo (REGRESSION)

- [ ] Notifications → each channel you use (Notification Center, Mail, Messages, Shortcuts, webhook such as ntfy): fill it in and press Send test. You get "Test sent" and the message arrives. Invalid input shows its hint.
- [ ] A real alarm sends to every configured channel; with "Also notify when armed" on, arming does too.
- [ ] Intruder Photo: an alarm takes a photo, the camera light turns off afterwards, the photo is exposed properly (not black), and it's attached to notifications. Show Photos opens the folder. Denying camera access shows "Camera access denied" with Open Privacy Settings.

## 12. Settings and the event log (REGRESSION)

- [ ] While armed, Settings shows "Disarm to change settings" and controls are disabled.
- [ ] Every setting survives a quit and relaunch, including Lid close alarm, which used to switch itself off on quit.
- [ ] If you upgraded from an upstream install: your sound, detection distance and trusted devices carried over.
- [ ] Event Log → View Log lists recent entries; the count updates.
- [ ] Launch at Login works after a restart.

## When something fails

Note the step, what you expected and what happened. Grab the Event Log (View Log) and, for crashes, `~/Library/Logs/DiagnosticReports/MacGuard*`. Commits on `main` are small and each one builds and passes the tests, so `git bisect` can find the change behind a regression.
