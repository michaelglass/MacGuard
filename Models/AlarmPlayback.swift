// AlarmPlayback.swift
// MacGuard - Anti-Theft Alarm for macOS

import Foundation

/// Alarm audio decisions as a pure function. `Sound` is the loaded player
/// (AVAudioPlayer in the app), generic so tests need no audio file.
enum AlarmPlayback<Sound: Equatable> {
    /// An output device's levels, read when a message is built.
    struct Reading: Equatable {
        let device: AudioDevice
        /// nil when the device has no volume control
        let volume: Float?
        let isMuted: Bool
    }

    /// What the shell reads when the alarm goes off.
    struct Start: Equatable {
        let targetVolume: Float
        let speaker: Reading?
        let output: Reading?
    }

    /// Where the alarm sounds.
    enum Route: Equatable {
        /// Kept on the built-in speaker. `displaced` is the output it last replaced,
        /// put back on stop.
        case speaker(AudioDevice, displaced: AudioDevice?)
        /// No built-in speaker: the alarm follows the output.
        case followOutput
    }

    enum Output: Equatable {
        case sound(Sound)
        /// No playable sound: system beeps.
        case beeping
    }

    struct Playing: Equatable {
        let targetVolume: Float
        var route: Route
        /// The output's volume before the alarm; nil when it had none to read.
        let savedVolume: Float?
        /// The device whose volume and mute are watched.
        var watched: AudioDevice?
        let output: Output
    }

    enum State: Equatable {
        case idle(prepared: Sound?)
        case playing(Playing)
    }

    enum Msg: Equatable {
        case prepare
        case preloaded(Sound?)
        case unprepare
        case start(Start)
        case soundLoaded(Sound?, then: Start)
        /// The default output, or its volume or mute, changed.
        case outputChanged(AudioDevice?)
        case outputRead(Reading?)
        case stop
    }

    /// Side effects the shell performs, in order. Volume and mute act on the
    /// default output as it is when the command runs.
    enum Cmd: Equatable {
        case preload
        case loadSound(then: Start)
        case setDefaultOutput(AudioDevice)
        case setOutputVolume(Float)
        case unmuteOutput
        /// Read the default output and send `.outputRead`.
        case readOutput
        case watch(AudioDevice?)
        case unwatch
        case playSound(Sound)
        /// A device change can stop the player.
        case resumeSound(Sound)
        case stopSound(Sound)
        case startBeeping
        case stopBeeping
        case log(String)
    }

    static func update(_ state: State, _ msg: Msg) -> (State, [Cmd]) {
        switch (state, msg) {
        case (.idle(.none), .prepare):
            return (state, [.preload])
        case (.idle(.none), .preloaded(let sound)):
            return (.idle(prepared: sound), sound == nil ? [] : [.log("Audio pre-loaded and ready")])
        case (.idle, .unprepare):
            return (.idle(prepared: nil), [.log("Audio released")])
        case (.idle(.none), .start(let start)):
            return (state, [.loadSound(then: start)])
        case (.idle(.some(let sound)), .start(let start)):
            return begin(start, .sound(sound), playLog: "Playing alarm sound (pre-loaded)")
        case (.idle(.none), .soundLoaded(.some(let sound), let start)):
            return begin(start, .sound(sound), playLog: "Playing alarm sound")
        case (.idle(.none), .soundLoaded(.none, let start)):
            return begin(start, .beeping, playLog: "Alarm sound not found, using system beep")
        // stop runs on every disarm, played or not: nothing to restore.
        case (.idle, .stop):
            return (.idle(prepared: nil), [.log("Alarm stopped")])
        // Listener callbacks queued before the alarm stopped.
        case (.idle, .outputChanged), (.idle, .outputRead):
            return (state, [])
        case (.idle(.some), .prepare), (.idle(.some), .preloaded), (.idle(.some), .soundLoaded):
            return (state, [])

        case (.playing(let playing), .outputChanged(let output)):
            return outputChanged(playing, output)
        case (.playing(let playing), .outputRead(let reading)):
            return enforce(playing, reading)
        case (.playing(let playing), .stop):
            return (.idle(prepared: nil), stop(playing))
        case (.playing, .prepare), (.playing, .preloaded), (.playing, .unprepare),
             (.playing, .start), (.playing, .soundLoaded):
            return (state, [])
        }
    }

    private static func begin(_ start: Start, _ output: Output, playLog: String) -> (State, [Cmd]) {
        var cmds: [Cmd] = []
        let route: Route
        /// Where the alarm will sound, once any move is done.
        let alarmOutput: Reading?
        if let speaker = start.speaker {
            cmds.append(.log("Found built-in speaker: device ID \(speaker.device)"))
            if let current = start.output, current.device != speaker.device {
                route = .speaker(speaker.device, displaced: current.device)
                alarmOutput = speaker
                cmds += [.setDefaultOutput(speaker.device),
                         .log("Switched from device \(current.device) to built-in speaker \(speaker.device)")]
            } else {
                route = .speaker(speaker.device, displaced: nil)
                alarmOutput = start.output
                cmds.append(.log("Already using built-in speaker"))
            }
        } else {
            route = .followOutput
            alarmOutput = start.output
            cmds.append(.log("Could not find built-in speaker, using current device"))
        }

        let savedVolume = alarmOutput?.volume
        cmds += [.log("Saved original volume: \(savedVolume.map { String($0) } ?? "unknown")"),
                 .setOutputVolume(start.targetVolume),
                 .unmuteOutput,
                 .watch(alarmOutput?.device)]
        switch output {
        case .sound(let sound): cmds.append(.playSound(sound))
        case .beeping: cmds.append(.startBeeping)
        }
        cmds.append(.log(playLog))

        let playing = Playing(targetVolume: start.targetVolume, route: route, savedVolume: savedVolume,
                              watched: alarmOutput?.device, output: output)
        return (.playing(playing), cmds)
    }

    private static func outputChanged(_ playing: Playing, _ output: AudioDevice?) -> (State, [Cmd]) {
        var playing = playing
        var cmds: [Cmd] = []
        switch playing.route {
        // Connecting headphones moves the default output, and the alarm with it.
        case .speaker(let speaker, _):
            if let output, output != speaker {
                playing.route = .speaker(speaker, displaced: output)
                cmds += [.setDefaultOutput(speaker),
                         .log("Output moved to device \(output) - alarm kept on built-in speaker")]
            }
        case .followOutput:
            break
        }
        switch playing.output {
        case .sound(let sound): cmds.append(.resumeSound(sound))
        case .beeping: break
        }
        cmds.append(.readOutput)
        return (.playing(playing), cmds)
    }

    private static func enforce(_ playing: Playing, _ reading: Reading?) -> (State, [Cmd]) {
        var playing = playing
        var cmds: [Cmd] = []
        // No built-in speaker to return to: follow the new device instead.
        if reading?.device != playing.watched {
            playing.watched = reading?.device
            cmds.append(.watch(reading?.device))
        }
        let target = playing.targetVolume
        if let reading {
            if reading.isMuted {
                cmds += [.unmuteOutput, .setOutputVolume(target), .log("Mute blocked - volume restored")]
            } else if let current = reading.volume, current < target - 0.05 {
                cmds += [.setOutputVolume(target),
                         .log("Volume restored from \(Int(current * 100))% to \(Int(target * 100))%")]
            }
        }
        return (.playing(playing), cmds)
    }

    /// Restores only what the alarm changed.
    private static func stop(_ playing: Playing) -> [Cmd] {
        var cmds: [Cmd] = [.unwatch]
        switch playing.output {
        case .sound(let sound): cmds.append(.stopSound(sound))
        case .beeping: cmds.append(.stopBeeping)
        }
        if let volume = playing.savedVolume { cmds.append(.setOutputVolume(volume)) }
        switch playing.route {
        case .speaker(_, displaced: .some(let device)):
            cmds += [.setDefaultOutput(device), .log("Restored output device to \(device)")]
        case .speaker(_, displaced: .none), .followOutput:
            break
        }
        cmds.append(.log("Alarm stopped"))
        return cmds
    }
}
