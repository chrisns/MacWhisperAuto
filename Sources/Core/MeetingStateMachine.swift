import Foundation

@MainActor
final class MeetingStateMachine {
    private(set) var state: MeetingState = .idle

    /// Pure transition function - returns new state and side effects.
    /// Side effects are RETURNED, never executed inside this function.
    func transition(on signal: MeetingSignal) -> [SideEffect] {
        let oldState = state
        var effects: [SideEffect] = []

        switch (state, signal.isActive) {

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

        // DETECTING + inactive signal -> back to idle
        case (.detecting, false):
            effects.append(.cancelTimer(id: .startDebounce))
            state = .idle

        // RECORDING + active signal for SAME platform -> cancel grace timer if running
        case (.recording(let platform), true) where signal.platform == platform:
            // Grace timer may or may not be running; cancel is safe either way
            effects.append(.cancelTimer(id: .stopGrace))

        // RECORDING + active signal for DIFFERENT platform -> switchover
        case (.recording, true):
            effects.append(.stopRecording)
            effects.append(.cancelTimer(id: .stopGrace))
            state = .detecting(platform: signal.platform, since: signal.timestamp)
            effects.append(.startTimer(duration: 5.0, id: .startDebounce))

        // RECORDING + inactive signal -> start grace period
        case (.recording, false):
            effects.append(.startTimer(duration: 15.0, id: .stopGrace))

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
        effects.append(.cancelTimer(id: .startDebounce))
        effects.append(.cancelTimer(id: .stopGrace))
        if oldState != .idle {
            effects.append(.logTransition(from: oldState, to: .idle))
        }
        return effects
    }
}
