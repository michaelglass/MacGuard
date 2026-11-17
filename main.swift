// main.swift
// MacGuard - Anti-Theft Alarm for macOS

// Also runs as the headless tamper watchdog (see TamperGuard.swift).
if CommandLine.arguments.contains(Watchdog.argument) {
    Watchdog.run()
} else {
    // Before anything reads settings. The watchdog reads none, so it skips this.
    SettingsMigration.run(.standard)
    MacGuardApp.main()
}
