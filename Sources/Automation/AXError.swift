import Foundation

enum AXError: Error, CustomStringConvertible, Sendable {
    case macWhisperNotRunning
    case elementNotFound(description: String)
    case actionFailed(element: String, action: String, code: Int32)
    case timeout

    var description: String {
        switch self {
        case .macWhisperNotRunning: "MacWhisper is not running"
        case .elementNotFound(let desc): "Element not found: \(desc)"
        case .actionFailed(let el, let action, let code):
            "Action '\(action)' failed on '\(el)' (code: \(code))"
        case .timeout: "AX operation timed out"
        }
    }
}
