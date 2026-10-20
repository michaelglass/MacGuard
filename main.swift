// main.swift
// MacGuard - Anti-Theft Alarm for macOS

// The same binary runs either as the menu bar app or, when launched by the
// tamper launchd agent, as a headless watchdog (see TamperGuard.swift).
if CommandLine.arguments.contains(Watchdog.argument) {
    Watchdog.run()
} else {
    MacGuardApp.main()
}
