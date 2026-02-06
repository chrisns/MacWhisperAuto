import Foundation

struct MeetingSignal: Sendable {
    let platform: Platform
    let isActive: Bool
    let confidence: SignalConfidence
    let source: SignalSource
    let timestamp: Date
}

enum SignalConfidence: Sendable {
    case high, medium, low
}

enum SignalSource: String, Sendable {
    case coreAudio, iopmAssertion, cgWindowList, webSocket, nsWorkspace, axAutomation, networkUDP
}

enum SideEffect: Sendable {
    case startRecording(Platform)
    case stopRecording
    case startTimer(duration: TimeInterval, id: TimerID)
    case cancelTimer(id: TimerID)
    case logTransition(from: MeetingState, to: MeetingState)
}

enum TimerID: Hashable, Sendable {
    case startDebounce
    case stopGrace
}

enum MeetingState: Equatable, Sendable {
    case idle
    case detecting(platform: Platform, since: Date)
    case recording(platform: Platform)
    case error(ErrorKind)

    static func == (lhs: MeetingState, rhs: MeetingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): true
        case (.detecting(let lp, _), .detecting(let rp, _)): lp == rp
        case (.recording(let lp), .recording(let rp)): lp == rp
        case (.error(let le), .error(let re)): le == re
        default: false
        }
    }
}

enum ErrorKind: Equatable, Sendable {
    case macWhisperUnresponsive
    case macWhisperNotRunning
    case axElementNotFound(String)
    case permissionDenied(Permission)
    case webSocketPortUnavailable

    static func == (lhs: ErrorKind, rhs: ErrorKind) -> Bool {
        switch (lhs, rhs) {
        case (.macWhisperUnresponsive, .macWhisperUnresponsive): true
        case (.macWhisperNotRunning, .macWhisperNotRunning): true
        case (.axElementNotFound(let l), .axElementNotFound(let r)): l == r
        case (.permissionDenied(let l), .permissionDenied(let r)): l == r
        case (.webSocketPortUnavailable, .webSocketPortUnavailable): true
        default: false
        }
    }
}

enum Permission: String, Sendable {
    case accessibility, screenRecording
}

extension ErrorKind {
    var userDescription: String {
        switch self {
        case .macWhisperUnresponsive: "MacWhisper is not responding"
        case .macWhisperNotRunning: "MacWhisper is not running"
        case .axElementNotFound(let desc): "UI element not found: \(desc)"
        case .permissionDenied(let perm): "\(perm.rawValue) permission denied"
        case .webSocketPortUnavailable: "WebSocket port 8765 unavailable"
        }
    }
}
