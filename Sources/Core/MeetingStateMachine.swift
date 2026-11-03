import Foundation

@MainActor
final class MeetingStateMachine {
    private(set) var state: MeetingState = .idle

    /// True while the stop grace timer runs. Repeated inactive signals must not
    /// restart it: with two browser connections, heartbeats arrive about every
    /// 10s, so a timer restarted on each one would never reach 15s.
    private(set) var stopGracePending = false

    /// Platform whose recording the user stopped in MacWhisper while the
    /// meeting was still active. Active signals from it do not start a new
    /// recording until it reports inactive (the meeting ended).
    private(set) var suppressedPlatform: Platform?

    /// Pure transition function - returns new state and side effects.
    /// Side effects are RETURNED, never executed inside this function.
    func transition(on signal: MeetingSignal) -> [SideEffect] {
        let oldState = state
        var effects: [SideEffect] = []

        // An inactive signal from the suppressed platform means its meeting
        // ended, so the next meeting on it may record again.
        if !signal.isActive && signal.platform == suppressedPlatform {
            suppressedPlatform = nil
        }

        switch (state, signal.isActive) {

        // IDLE + active signal from a platform the user stopped -> ignore
        case (.idle, true) where signal.platform == suppressedPlatform:
            break

        // IDLE + active signal -> start detecting
        case (.idle, true):
            state = .detecting(platform: signal.platform, since: signal.timestamp)
            effects.append(.startTimer(duration: 5.0, id: .startDebounce))

        // IDLE + inactive signal -> ignore
        case (.idle, false):
            break

        // DETECTING + active signal for SAME platform -> debounce timer already running
        case (.detecting(let platform, _), true) where signal.platform == platform:
            break

        // DETECTING + active signal for DIFFERENT platform -> switch detection target
        case (.detecting, true):
            effects.append(.cancelTimer(id: .startDebounce))
            state = .detecting(platform: signal.platform, since: signal.timestamp)
            effects.append(.startTimer(duration: 5.0, id: .startDebounce))

        // DETECTING + inactive signal from SAME platform -> back to idle
        case (.detecting(let platform, _), false) where signal.platform == platform:
            effects.append(.cancelTimer(id: .startDebounce))
            state = .idle

        // DETECTING + inactive signal from DIFFERENT platform -> ignore
        case (.detecting, false):
            break

        // RECORDING + active signal for SAME platform -> cancel grace timer if running
        case (.recording(let platform), true) where signal.platform == platform:
            // Grace timer may or may not be running; cancel is safe either way
            effects.append(.cancelTimer(id: .stopGrace))
            stopGracePending = false

        // RECORDING + active signal for DIFFERENT platform -> switchover
        case (.recording, true):
            effects.append(.stopRecording)
            effects.append(.cancelTimer(id: .stopGrace))
            stopGracePending = false
            state = .detecting(platform: signal.platform, since: signal.timestamp)
            effects.append(.startTimer(duration: 5.0, id: .startDebounce))

        // RECORDING + inactive signal from SAME platform -> start grace period,
        // unless it already runs (keep the first deadline)
        case (.recording(let platform), false) where signal.platform == platform:
            if !stopGracePending {
                effects.append(.startTimer(duration: 15.0, id: .stopGrace))
                stopGracePending = true
            }

        // RECORDING + inactive signal from DIFFERENT platform -> ignore
        case (.recording, false):
            break

        // ERROR + any signal -> stay in error (must be cleared explicitly)
        case (.error, _):
            break
        }

        if oldState != state {
            effects.append(.logTransition(from: oldState, to: state))
        }

        return effects
    }

    /// Called when start debounce timer fires (5s of consistent detection).
    func debounceTimerFired() -> [SideEffect] {
        guard case .detecting(let platform, _) = state else { return [] }
        let oldState = state
        state = .recording(platform: platform)
        return [
            .startRecording(platform),
            .logTransition(from: oldState, to: state)
        ]
    }

    /// Called when grace timer fires (15s of no signals).
    func graceTimerFired() -> [SideEffect] {
        stopGracePending = false
        guard case .recording = state else { return [] }
        let oldState = state
        state = .idle
        return [
            .stopRecording,
            .logTransition(from: oldState, to: state)
        ]
    }

    /// Transition to error state.
    func setError(_ error: ErrorKind) -> [SideEffect] {
        let oldState = state
        state = .error(error)
        stopGracePending = false
        // Don't stop recording on error - fail long over fail short
        let effects: [SideEffect] = [.logTransition(from: oldState, to: state)]
        return effects
    }

    /// Clear error state and return to idle.
    func clearError() -> [SideEffect] {
        guard case .error = state else { return [] }
        let oldState = state
        state = .idle
        return [.logTransition(from: oldState, to: state)]
    }

    /// Reset for sleep/wake.
    func reset() -> [SideEffect] {
        let oldState = state
        var effects: [SideEffect] = []
        if case .recording = oldState {
            effects.append(.stopRecording)
        }
        state = .idle
        stopGracePending = false
        suppressedPlatform = nil
        effects.append(.cancelTimer(id: .startDebounce))
        effects.append(.cancelTimer(id: .stopGrace))
        if oldState != .idle {
            effects.append(.logTransition(from: oldState, to: .idle))
        }
        return effects
    }

    /// MacWhisper stopped recording without us (the user pressed End Meeting
    /// or Finish). Go to idle without a stop command, and do not restart a
    /// recording for this platform until its meeting ends.
    func recordingStoppedExternally() -> [SideEffect] {
        guard case .recording(let platform) = state else { return [] }
        let oldState = state
        state = .idle
        stopGracePending = false
        suppressedPlatform = platform
        return [
            .cancelTimer(id: .stopGrace),
            .logTransition(from: oldState, to: state)
        ]
    }
}
