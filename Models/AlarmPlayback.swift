// AlarmPlayback.swift
// MacGuard - Anti-Theft Alarm for macOS

import Foundation

/// What a sounding alarm puts back on stop. Recorded before the alarm changes
/// anything, so an instance relaunched after a kill can restore these rather than
/// the speaker and volume the killed alarm left behind.
struct AudioRestore: Equatable {
    /// The output the alarm moved off; nil when it did not move it.
    let displaced: AudioDevice?
    /// The output's volume before the alarm; nil when it had none to read.
    let volume: Float?
}

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

        var displaced: AudioDevice? {
            switch self {
            case .speaker(_, let displaced): return displaced
            case .followOutput: return nil
            }
        }
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

        var restore: AudioRestore { AudioRestore(displaced: route.displaced, volume: savedVolume) }
    }

    enum Model: Equatable {
        case idle(prepared: Sound?)
        /// Relaunched after being killed mid-alarm: the output and volume now are
        /// that alarm's, so the next start restores what it recorded instead.
        case inherited(AudioRestore)
        case playing(Playing)
    }

    /// Whose audio state stop puts back.
    private enum Baseline {
        /// The output as read at start.
        case current
        case inherited(AudioRestore)
    }

    enum Msg: Equatable {
        case prepare
        case preloaded(Sound?)
        case unprepare
        /// A killed instance's alarm recorded this restore.
        case inherit(AudioRestore)
        case start(Start)
        case soundLoaded(Sound?, then: Start)
        /// The default output, or its volume or mute, changed.
        case outputChanged(AudioDevice?)
        case outputRead(Reading?)
        case stop
    }

    /// Side effects the shell performs, in order. Volume and mute act on the
    /// default output as it is when the effect runs.
    enum Effect: Equatable {
        /// Make the restore durable. Emitted before the alarm changes anything,
        /// and again whenever what stop would put back changes.
        case recordRestore(AudioRestore)
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
        case log(ActivityLogCategory, String)
    }

    static func update(_ model: Model, _ msg: Msg) -> (Model, [Effect]) {
        switch (model, msg) {
        case (.idle(.none), .prepare):
            return (model, [.preload])
        case (.idle(.none), .preloaded(let sound)):
            return (.idle(prepared: sound), sound == nil ? [] : [.log(.alarm, "Audio pre-loaded and ready")])
        case (.idle, .unprepare):
            return (.idle(prepared: nil), [.log(.alarm, "Audio released")])
        case (.idle(.none), .start(let start)):
            return (model, [.loadSound(then: start)])
        case (.idle(.some(let sound)), .start(let start)):
            return begin(start, .sound(sound), .current, playLog: "Playing alarm sound (pre-loaded)")
        case (.idle(.none), .soundLoaded(.some(let sound), let start)):
            return begin(start, .sound(sound), .current, playLog: "Playing alarm sound")
        case (.idle(.none), .soundLoaded(.none, let start)):
            return begin(start, .beeping, .current, playLog: "Alarm sound not found, using system beep")
        case (.idle, .inherit(let restore)):
            return (.inherited(restore), [.log(.alarm, "Restarted mid-alarm - keeping the audio settings recorded before it")])
        // stop runs on every disarm, played or not: nothing to restore.
        case (.idle, .stop):
            return (.idle(prepared: nil), [.log(.alarm, "Alarm stopped")])
        // Listener callbacks queued before the alarm stopped.
        case (.idle, .outputChanged), (.idle, .outputRead):
            return (model, [])
        case (.idle(.some), .prepare), (.idle(.some), .preloaded), (.idle(.some), .soundLoaded):
            return (model, [])

        case (.inherited, .start(let start)):
            return (model, [.loadSound(then: start)])
        case (.inherited(let restore), .soundLoaded(.some(let sound), let start)):
            return begin(start, .sound(sound), .inherited(restore), playLog: "Playing alarm sound")
        case (.inherited(let restore), .soundLoaded(.none, let start)):
            return begin(start, .beeping, .inherited(restore), playLog: "Alarm sound not found, using system beep")
        // Stopped before sounding again: the killed alarm's changes still need undoing.
        case (.inherited(let restore), .stop):
            return (.idle(prepared: nil), self.restore(restore) + [.log(.alarm, "Alarm stopped")])
        case (.inherited, .prepare), (.inherited, .preloaded), (.inherited, .unprepare), (.inherited, .inherit),
             (.inherited, .outputChanged), (.inherited, .outputRead):
            return (model, [])

        case (.playing(let playing), .outputChanged(let output)):
            return outputChanged(playing, output)
        case (.playing(let playing), .outputRead(let reading)):
            return enforce(playing, reading)
        case (.playing(let playing), .stop):
            return (.idle(prepared: nil), stop(playing))
        case (.playing, .prepare), (.playing, .preloaded), (.playing, .unprepare), (.playing, .inherit),
             (.playing, .start), (.playing, .soundLoaded):
            return (model, [])
        }
    }

    private static func begin(_ start: Start, _ output: Output, _ baseline: Baseline, playLog: String) -> (Model, [Effect]) {
        var effects: [Effect] = []
        var route: Route
        /// Where the alarm will sound, once any move is done.
        let alarmOutput: Reading?
        if let speaker = start.speaker {
            effects.append(.log(.alarm, "Found built-in speaker: device ID \(speaker.device)"))
            if let current = start.output, current.device != speaker.device {
                route = .speaker(speaker.device, displaced: current.device)
                alarmOutput = speaker
                effects += [.setDefaultOutput(speaker.device),
                         .log(.alarm, "Switched from device \(current.device) to built-in speaker \(speaker.device)")]
            } else {
                route = .speaker(speaker.device, displaced: nil)
                alarmOutput = start.output
                effects.append(.log(.alarm, "Already using built-in speaker"))
            }
        } else {
            route = .followOutput
            alarmOutput = start.output
            effects.append(.log(.alarm, "Could not find built-in speaker, using current device"))
        }

        let savedVolume: Float?
        switch baseline {
        case .current:
            savedVolume = alarmOutput?.volume
        // What is read now is the killed alarm's: its record wins. An output moved
        // since the kill is put back only when the alarm had not moved one.
        // Without a built-in speaker there is no route to restore through.
        case .inherited(let restore):
            savedVolume = restore.volume
            switch route {
            case .speaker(let speaker, let displacedNow):
                route = .speaker(speaker, displaced: restore.displaced ?? displacedNow)
            case .followOutput:
                break
            }
        }
        let playing = Playing(targetVolume: start.targetVolume, route: route, savedVolume: savedVolume,
                              watched: alarmOutput?.device, output: output)
        effects.insert(.recordRestore(playing.restore), at: 0)
        effects += [.log(.alarm, "Saved original volume: \(savedVolume.map { String($0) } ?? "unknown")"),
                 .setOutputVolume(start.targetVolume),
                 .unmuteOutput,
                 .watch(alarmOutput?.device)]
        switch output {
        case .sound(let sound): effects.append(.playSound(sound))
        case .beeping: effects.append(.startBeeping)
        }
        effects.append(.log(.alarm, playLog))
        return (.playing(playing), effects)
    }

    private static func outputChanged(_ playing: Playing, _ output: AudioDevice?) -> (Model, [Effect]) {
        var playing = playing
        var effects: [Effect] = []
        switch playing.route {
        // Connecting headphones moves the default output, and the alarm with it.
        case .speaker(let speaker, _):
            if let output, output != speaker {
                if output != playing.route.displaced {
                    playing.route = .speaker(speaker, displaced: output)
                    effects.append(.recordRestore(playing.restore))
                }
                effects += [.setDefaultOutput(speaker),
                         .log(.alarm, "Output moved to device \(output) - alarm kept on built-in speaker")]
            }
        case .followOutput:
            break
        }
        switch playing.output {
        case .sound(let sound): effects.append(.resumeSound(sound))
        case .beeping: break
        }
        effects.append(.readOutput)
        return (.playing(playing), effects)
    }

    private static func enforce(_ playing: Playing, _ reading: Reading?) -> (Model, [Effect]) {
        var playing = playing
        var effects: [Effect] = []
        // No built-in speaker to return to: follow the new device instead.
        if reading?.device != playing.watched {
            playing.watched = reading?.device
            effects.append(.watch(reading?.device))
        }
        let target = playing.targetVolume
        if let reading {
            if reading.isMuted {
                effects += [.unmuteOutput, .setOutputVolume(target), .log(.alarm, "Mute blocked - volume restored")]
            } else if let current = reading.volume, current < target - 0.05 {
                effects += [.setOutputVolume(target),
                         .log(.alarm, "Volume restored from \(Int(current * 100))% to \(Int(target * 100))%")]
            }
        }
        return (.playing(playing), effects)
    }

    /// Restores only what the alarm changed.
    private static func stop(_ playing: Playing) -> [Effect] {
        var effects: [Effect] = [.unwatch]
        switch playing.output {
        case .sound(let sound): effects.append(.stopSound(sound))
        case .beeping: effects.append(.stopBeeping)
        }
        effects += restore(playing.restore)
        effects.append(.log(.alarm, "Alarm stopped"))
        return effects
    }

    private static func restore(_ restore: AudioRestore) -> [Effect] {
        var effects: [Effect] = []
        if let volume = restore.volume { effects.append(.setOutputVolume(volume)) }
        if let device = restore.displaced {
            effects += [.setDefaultOutput(device), .log(.alarm, "Restored output device to \(device)")]
        }
        return effects
    }
}
