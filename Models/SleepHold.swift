// SleepHold.swift
// MacGuard - Anti-Theft Alarm for macOS

import Foundation

/// Lid-close protection: closing the lid must not sleep an armed Mac.
///
/// The only switch that stops lid-close sleep is `pmset disablesleep`, a system-wide setting
/// that outlives the process that set it. So MacGuard never sets it directly. A root watcher,
/// started with one admin prompt, sets it only on request over a pipe, and clears it when
/// it starts and when the pipe closes. The pipe closes whenever MacGuard exits, however it
/// exits, so a stale "sleep disabled" needs the watcher itself to die first.
enum SleepHold {
    enum Link: Equatable {
        case disabled
        /// The admin prompt is up.
        case authorizing
        /// The prompt was cancelled or failed; enabling again retries.
        case refused
        /// Connected to the watcher. `sleepDisabled` is the last value sent to it.
        case connected(sleepDisabled: Bool)
        /// The watcher went away; enabling again retries.
        case lost
    }

    struct Model: Equatable {
        fileprivate(set) var link: Link = .disabled
        /// Arming, armed, triggered or alarming: anything but idle.
        fileprivate(set) var guarding = false
    }

    enum Msg: Equatable {
        case enable
        case disable
        case guardingChanged(Bool)
        /// The watcher runs and the pipe is open.
        case authorized
        case refused
        /// A write to the pipe failed.
        case lost
    }

    enum Effect: Equatable {
        case startWatcher
        /// Closes the pipe, if open; the watcher then re-enables sleep and exits.
        case stopWatcher
        case disableSleep(Bool)
        case log(String)
    }

    static func update(_ model: Model, _ msg: Msg) -> (Model, [Effect]) {
        var model = model
        switch msg {
        case .enable:
            switch model.link {
            case .disabled, .refused, .lost:
                model.link = .authorizing
                return (model, [.startWatcher])
            case .authorizing, .connected:
                return (model, [])
            }

        case .disable:
            switch model.link {
            case .authorizing, .connected:
                model.link = .disabled
                return (model, [.stopWatcher, .log("Lid-close protection off")])
            case .disabled, .refused, .lost:
                model.link = .disabled
                return (model, [])
            }

        case .guardingChanged(let guarding):
            model.guarding = guarding
            switch model.link {
            case .connected(let sent) where sent != guarding:
                model.link = .connected(sleepDisabled: guarding)
                return (model, [.disableSleep(guarding)])
            case .connected, .disabled, .authorizing, .refused, .lost:
                return (model, [])
            }

        case .authorized:
            switch model.link {
            case .authorizing:
                model.link = .connected(sleepDisabled: model.guarding)
                return (
                    model,
                    (model.guarding ? [.disableSleep(true)] : []) + [.log("Lid-close protection ready")]
                )
            // Disabled while the prompt was up: the pipe that just opened is closed again.
            case .disabled:
                return (model, [.stopWatcher])
            case .refused, .connected, .lost:
                return (model, [])
            }

        case .refused:
            switch model.link {
            case .authorizing:
                model.link = .refused
                return (model, [.log("Lid-close protection not authorized")])
            case .disabled, .refused, .connected, .lost:
                return (model, [])
            }

        case .lost:
            switch model.link {
            case .connected:
                model.link = .lost
                return (model, [.stopWatcher, .log("Lid-close protection watcher stopped unexpectedly")])
            case .disabled, .authorizing, .refused, .lost:
                return (model, [])
            }
        }
    }
}
