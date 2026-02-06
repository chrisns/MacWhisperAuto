import Foundation

@MainActor
final class DetectionCoordinator {
    private let stateMachine: MeetingStateMachine
    private let appState: AppState
    private var detectors: [any MeetingDetector] = []

    // Side effect handlers (set by AppDelegate during wiring)
    var onStartRecording: (@MainActor (Platform) -> Void)?
    var onStopRecording: (@MainActor () -> Void)?

    // Timer management
    private var timers: [TimerID: DispatchSourceTimer] = [:]

    init(stateMachine: MeetingStateMachine, appState: AppState) {
        self.stateMachine = stateMachine
        self.appState = appState
    }

    func registerDetector(_ detector: any MeetingDetector) {
        detectors.append(detector)
    }

    func start() {
        for detector in detectors {
            detector.start()
        }
    }

    func stop() {
        for detector in detectors {
            detector.stop()
        }
        cancelAllTimers()
    }

    /// Called by detectors - dispatches to @MainActor.
    nonisolated func handleSignal(_ signal: MeetingSignal) {
        Task { @MainActor in
            self.processSignal(signal)
        }
    }

    private func processSignal(_ signal: MeetingSignal) {
        let effects = stateMachine.transition(on: signal)
        appState.updateState(stateMachine.state)
        appState.addActivity(
            "\(signal.source.rawValue): \(signal.platform.displayName) \(signal.isActive ? "active" : "inactive")",
            platform: signal.platform
        )
        dispatchEffects(effects)
    }

    private func dispatchEffects(_ effects: [SideEffect]) {
        for effect in effects {
            switch effect {
            case .startRecording(let platform):
                onStartRecording?(platform)
            case .stopRecording:
                onStopRecording?()
            case .startTimer(let duration, let id):
                startTimer(duration: duration, id: id)
            case .cancelTimer(let id):
                cancelTimer(id: id)
            case .logTransition(let from, let to):
                DetectionLogger.shared.transition(from: from, to: to)
            }
        }
    }

    private func startTimer(duration: TimeInterval, id: TimerID) {
        cancelTimer(id: id)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + duration)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.handleTimerFired(id: id)
            }
        }
        timer.resume()
        timers[id] = timer
    }

    private func cancelTimer(id: TimerID) {
        timers[id]?.cancel()
        timers[id] = nil
    }

    private func cancelAllTimers() {
        for (_, timer) in timers {
            timer.cancel()
        }
        timers.removeAll()
    }

    private func handleTimerFired(id: TimerID) {
        let effects: [SideEffect]
        switch id {
        case .startDebounce:
            effects = stateMachine.debounceTimerFired()
        case .stopGrace:
            effects = stateMachine.graceTimerFired()
        }
        appState.updateState(stateMachine.state)
        dispatchEffects(effects)
        timers[id] = nil
    }

    /// Called on wake from sleep - reset state machine and restart detectors.
    func handleWake() {
        let effects = stateMachine.reset()
        appState.updateState(stateMachine.state)
        dispatchEffects(effects)
        cancelAllTimers()
        // Restart detectors to re-poll
        for detector in detectors {
            detector.stop()
            detector.start()
        }
    }

    /// Called before sleep - stop everything.
    func handleSleep() {
        stop()
        let effects = stateMachine.reset()
        appState.updateState(stateMachine.state)
        dispatchEffects(effects)
    }

    /// Report an error to the state machine.
    func reportError(_ error: ErrorKind) {
        let effects = stateMachine.setError(error)
        appState.updateState(stateMachine.state)
        dispatchEffects(effects)
    }

    /// Clear error and return to idle.
    func clearError() {
        let effects = stateMachine.clearError()
        appState.updateState(stateMachine.state)
        dispatchEffects(effects)
    }
}
