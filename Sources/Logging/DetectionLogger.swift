import Foundation
import OSLog

// MARK: - os_log categories

struct Log {
    static let subsystem = "com.macwhisperauto"

    static let detection = Logger(subsystem: subsystem, category: "detection")
    static let stateMachine = Logger(subsystem: subsystem, category: "stateMachine")
    static let automation = Logger(subsystem: subsystem, category: "automation")
    static let webSocket = Logger(subsystem: subsystem, category: "webSocket")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
}

// MARK: - DetectionLogger

final class DetectionLogger: Sendable {
    static let shared = DetectionLogger()

    enum Category: String, Sendable {
        case detection, stateMachine, automation, webSocket, permissions, lifecycle
    }

    // MARK: - Main logging method

    func log(
        _ category: Category,
        level: OSLogType = .info,
        platform: Platform? = nil,
        signal: SignalSource? = nil,
        active: Bool? = nil,
        action: String? = nil,
        state: String? = nil,
        _ message: String
    ) {
        let logger = osLogger(for: category)
        let levelName = levelString(level)

        // os_log - build a descriptive single-line message
        let osMessage = buildOSLogMessage(
            message, platform: platform, signal: signal,
            active: active, action: action, state: state
        )
        logger.log(level: level, "\(osMessage, privacy: .public)")

        // File log
        let entry = LogEntry(
            ts: Date(),
            cat: category.rawValue,
            level: levelName,
            platform: platform?.rawValue,
            signal: signal?.rawValue,
            active: active,
            action: action,
            state: state,
            message: message
        )
        Task { await FileLogger.shared.write(entry) }
    }

    // MARK: - Convenience: detection

    func detection(
        _ message: String,
        platform: Platform? = nil,
        signal: SignalSource? = nil,
        active: Bool? = nil
    ) {
        log(.detection, level: .debug, platform: platform, signal: signal, active: active, message)
    }

    // MARK: - Convenience: stateMachine

    func stateMachine(_ message: String, from: String? = nil, to: String? = nil) {
        let state = to
        let action: String? = if let from, let to { "\(from) -> \(to)" } else { nil }
        log(.stateMachine, level: .info, action: action, state: state, message)
    }

    // MARK: - Convenience: automation

    func automation(_ message: String, action: String? = nil) {
        log(.automation, level: .default, action: action, message)
    }

    // MARK: - Convenience: webSocket

    func webSocket(_ message: String) {
        log(.webSocket, level: .info, message)
    }

    // MARK: - Convenience: permissions

    func permissions(_ message: String) {
        log(.permissions, level: .info, message)
    }

    // MARK: - Convenience: lifecycle

    func lifecycle(_ message: String) {
        log(.lifecycle, level: .info, message)
    }

    // MARK: - Convenience: error

    func error(_ category: Category, _ message: String) {
        log(category, level: .error, message)
    }

    // MARK: - Convenience: signal (structured detection event)

    func signal(
        platform: Platform,
        source: SignalSource,
        active: Bool,
        state: MeetingState
    ) {
        let stateStr = stateLabel(state)
        log(
            .detection, level: .debug,
            platform: platform, signal: source,
            active: active, action: "none", state: stateStr,
            "\(platform.rawValue) via \(source.rawValue) active=\(active)"
        )
    }

    // MARK: - Convenience: transition

    func transition(from: MeetingState, to: MeetingState) {
        let fromStr = stateLabel(from)
        let toStr = stateLabel(to)
        stateMachine("\(fromStr) -> \(toStr)", from: fromStr, to: toStr)
    }

    // MARK: - Private helpers

    private func osLogger(for category: Category) -> Logger {
        switch category {
        case .detection: Log.detection
        case .stateMachine: Log.stateMachine
        case .automation: Log.automation
        case .webSocket: Log.webSocket
        case .permissions: Log.permissions
        case .lifecycle: Log.lifecycle
        }
    }

    private func levelString(_ level: OSLogType) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .default: "default"
        case .error: "error"
        case .fault: "fault"
        default: "unknown"
        }
    }

    private func buildOSLogMessage(
        _ message: String,
        platform: Platform?,
        signal: SignalSource?,
        active: Bool?,
        action: String?,
        state: String?
    ) -> String {
        var parts = [message]
        if let platform { parts.append("platform=\(platform.rawValue)") }
        if let signal { parts.append("signal=\(signal.rawValue)") }
        if let active { parts.append("active=\(active)") }
        if let action { parts.append("action=\(action)") }
        if let state { parts.append("state=\(state)") }
        return parts.joined(separator: " ")
    }

    func stateLabel(_ state: MeetingState) -> String {
        switch state {
        case .idle: "idle"
        case .detecting(let p, _): "detecting(\(p.rawValue))"
        case .recording(let p): "recording(\(p.rawValue))"
        case .error(let e): "error(\(e))"
        }
    }
}

// MARK: - LogEntry

struct LogEntry: Encodable, Sendable {
    let ts: Date
    let cat: String
    let level: String
    let platform: String?
    let signal: String?
    let active: Bool?
    let action: String?
    let state: String?
    let message: String
}

// MARK: - FileLogger (actor for thread-safe file I/O)

actor FileLogger {
    static let shared = FileLogger()

    private let maxBytes: UInt64 = 10_485_760 // 10 MB
    private let logDir: URL
    private let logFile: URL
    private var handle: FileHandle?

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        logDir = home.appendingPathComponent("Library/Logs/MacWhisperAuto", isDirectory: true)
        logFile = logDir.appendingPathComponent("detection.jsonl")
    }

    func write(_ entry: LogEntry) {
        do {
            try ensureDirectory()
            try ensureHandle()
            try rotateIfNeeded()

            let data = try JSONEncoder.iso8601.encode(entry)
            handle?.write(data)
            handle?.write(Data([0x0A])) // newline
        } catch {
            Log.lifecycle.error("FileLogger write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private

    private func ensureDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logDir.path) {
            try fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        }
    }

    private func ensureHandle() throws {
        if handle == nil {
            let fm = FileManager.default
            if !fm.fileExists(atPath: logFile.path) {
                fm.createFile(atPath: logFile.path, contents: nil)
            }
            handle = try FileHandle(forWritingTo: logFile)
            handle?.seekToEndOfFile()
        }
    }

    private func rotateIfNeeded() throws {
        guard let h = handle else { return }
        let offset = h.offsetInFile
        guard offset >= maxBytes else { return }

        h.closeFile()
        handle = nil

        let rotated = logDir.appendingPathComponent("detection.1.jsonl")
        let fm = FileManager.default
        try? fm.removeItem(at: rotated)
        try fm.moveItem(at: logFile, to: rotated)

        fm.createFile(atPath: logFile.path, contents: nil)
        handle = try FileHandle(forWritingTo: logFile)
    }
}

// MARK: - JSONEncoder extension

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [] // compact, single line
        return enc
    }()
}
