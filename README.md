# MacGuard

![Version](https://img.shields.io/github/v/release/shenglong209/MacGuard?label=version&color=blue)
![macOS](https://img.shields.io/badge/macOS-13.0+-brightgreen)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
![License](https://img.shields.io/github/license/shenglong209/MacGuard?color=green)

![MacGuard Featured Image](featured-image.png)

Anti-theft alarm app for macOS. Protects your laptop in public places by triggering a loud alarm when unauthorized access is detected.

## Features

- **Menu Bar App** - Runs silently in the background with custom styled dropdown
- **Input Monitoring** - Detects keyboard, mouse, and trackpad activity
- **Sleep/Power Detection** - Triggers on lid close or power disconnect
- **Lid Close Alarm** - Instant alarm when lid closes (requires admin, prevents sleep)
- **Bluetooth Proximity** - Auto-arm when any trusted device leaves; auto-disarm only when a device that was away comes back
- **Multiple Trusted Devices** - Support up to 10 devices (Apple and non-Apple Bluetooth)
- **Dynamic Menu Bar Icon** - Icon reflects armed/disarmed status
- **Touch ID + PIN** - Secure authentication to disarm
- **Configurable Alarm** - Choose from 14 system sounds, custom audio files, or bundled "Don't Touch My Mac"
- **Auto-Lock** - Optional screen lock when armed (configurable)
- **Volume Control** - Adjustable alarm volume with preview

## Requirements

- macOS 13 Ventura or later
- Accessibility permission (for input monitoring)
- Bluetooth (for proximity detection)

## Installation

### Download (Recommended)

1. Download the latest DMG from [GitHub Releases](https://github.com/shenglong209/MacGuard/releases)
2. Open the DMG and drag MacGuard to Applications
3. **First launch** - Run `xattr -cr /Applications/MacGuard.app` in Terminal

### Auto-Update

MacGuard includes automatic update checking via Sparkle. Check for updates in Settings → About → "Check for Updates".

### Build from Source

```bash
git clone https://github.com/shenglong209/MacGuard.git
cd MacGuard
swift build -c release
./scripts/create-dmg.sh 1.3.4
```

The DMG will be at `dist/MacGuard-1.3.4.dmg`

### Checks

`mise check` checks formatting and lint (`mise format` fixes formatting), builds with complete concurrency checking and warnings as errors, and runs the tests. CI runs the same command on every pull request.

### Release Automation

Releases are automated via GitHub Actions:
- **Merge PR to main** → Automatically bumps patch version and releases
- Add `release:minor` or `release:major` label to PR for respective bumps

#### Code Signing for CI (Preserves Accessibility Permission)

To prevent users from needing to re-grant Accessibility permission after each update:

1. Export your Apple Development certificate:
   ```bash
   ./scripts/export-certificate.sh
   ```

2. Add GitHub secrets:
   - `SIGNING_CERTIFICATE_P12_BASE64`: The base64-encoded .p12 file
   - `SIGNING_CERTIFICATE_PASSWORD`: The password for the .p12 file

## Usage

1. **Grant Accessibility Permission**
   - Open Settings from menu bar
   - Click "Grant" next to Accessibility
   - Enable MacGuard in System Preferences → Privacy & Security → Accessibility

2. **Configure Trusted Devices** (optional)
   - Click "Manage Devices" in Settings → Trusted Devices
   - Add up to 10 Bluetooth devices (iPhone, AirPods, Apple Watch, or paired non-Apple devices)
   - A device that was away while armed disarms the alarm when it comes back. A device that stayed (say, a phone left on the desk) never disarms it.
   - Enable "Auto-arm when devices leave" to arm as soon as any trusted device leaves

3. **Set Backup PIN**
   - Click "Set PIN" in Security section
   - Enter 4-8 digit PIN

4. **Configure Behavior** (optional)
   - Toggle "Lock screen when armed" on/off
   - Enable "Lid close alarm" for instant alarm on lid close (requires admin password)
   - Choose alarm sound (system sounds, custom file, or bundled)
   - Adjust volume and preview with 🔊 button

5. **Arm MacGuard**
   - Click "Arm MacGuard" from menu bar
   - Screen locks automatically (if enabled)
   - Any input triggers 3-second countdown

6. **Disarm**
   - Touch ID (if available)
   - Enter PIN
   - Trusted device proximity (automatic)

## How It Works

```
┌─────────┐
│  IDLE   │  ← Disarmed, not monitoring
└────┬────┘
     │ arm
     ▼
┌─────────┐
│  ARMED  │  ← Monitoring input, sleep, power
└────┬────┘
     │ input detected
     ▼
┌─────────┐
│TRIGGERED│  ← 3-second countdown
└────┬────┘
     │ timeout
     ▼
┌─────────┐
│ALARMING │  ← Loud alarm at max volume
└─────────┘
```

## Project Structure

```
MacGuard/
├── MacGuardApp.swift           # App entry point
├── Managers/
│   ├── AlarmStateManager.swift      # State machine
│   ├── InputMonitor.swift           # CGEventTap monitoring
│   ├── SleepMonitor.swift           # Lid close detection
│   ├── PowerMonitor.swift           # Power disconnect
│   ├── BluetoothProximityManager.swift  # RSSI scanning
│   ├── AuthManager.swift            # Touch ID + Keychain
│   ├── AlarmAudioManager.swift      # Audio playback
│   └── UpdateManager.swift          # Sparkle auto-update
├── Views/
│   ├── MenuBarView.swift            # Menu bar dropdown
│   ├── SettingsView.swift           # Settings window
│   ├── CountdownOverlayView.swift   # Fullscreen overlay
│   ├── DeviceScannerView.swift      # Bluetooth scanner
│   ├── TrustedDevicesConfigView.swift  # Device management
│   └── ActivityLogView.swift        # Event log viewer
├── Models/
│   ├── AlarmState.swift
│   ├── TrustedDevice.swift
│   └── AppSettings.swift          # User preferences
└── Resources/
    ├── AppIcon.png
    ├── MenuBarIcon.png
    └── dont-touch-my-mac.mp3      # Bundled alarm sound
```

## Permissions

| Permission | Purpose |
|------------|---------|
| Accessibility | Global input monitoring via CGEventTap |
| Bluetooth | Trusted device proximity detection |
| Administrator | Lid close alarm (pmset disablesleep) |

## Documentation

Comprehensive documentation is available in the `docs/` directory:

- **[Project Overview & PDR](docs/project-overview-pdr.md)** - Product vision, features, requirements
- **[Codebase Summary](docs/codebase-summary.md)** - Technical overview, file structure, dependencies
- **[Code Standards](docs/code-standards.md)** - Swift patterns, naming conventions, best practices
- **[System Architecture](docs/system-architecture.md)** - State machine, data flow, component design
- **[Project Roadmap](docs/project-roadmap.md)** - Completed milestones, known issues, future plans
- **[Deployment Guide](docs/deployment-guide.md)** - Build instructions, release process, CI/CD

## Built With

This project was developed with the assistance of:

- **[Claude Code](https://claude.ai/code)** - Anthropic's AI-powered coding assistant
- **[ClaudeKit](https://claudekit.cc/?ref=BPLLTRW2)** - Skills and workflows for Claude Code

## License

MIT License

## Contributing

Pull requests welcome. For major changes, please open an issue first.
