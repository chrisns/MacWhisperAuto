import Foundation
import os

/// Detects Amazon Chime meetings via two complementary signals:
/// 1. CGWindowList: "Amazon Chime: Meeting Controls" window title (needs Screen Recording)
/// 2. Network UDP: Count of UDP sockets for Amazon Chime process (no permissions needed)
final class ChimeDetector: MeetingDetector, WindowListConsumer, @unchecked Sendable {
    private let onSignal: @Sendable (MeetingSignal) -> Void
    private let _isEnabled = OSAllocatedUnfairLock(initialState: false)
    private let _lastActive = OSAllocatedUnfairLock(initialState: false)

    // Network UDP state
    private let _lastNetworkActive = OSAllocatedUnfairLock(initialState: false)
    private var pollTimer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "com.macwhisperauto.chime.poll")
    private static let pollInterval: TimeInterval = 3.0
    private static let udpSocketThreshold = 2

    var isEnabled: Bool { _isEnabled.withLock { $0 } }

    init(onSignal: @escaping @Sendable (MeetingSignal) -> Void) {
        self.onSignal = onSignal
    }

    deinit {
        stop()
    }

    func start() {
        _isEnabled.withLock { $0 = true }
        startNetworkPolling()
        DetectionLogger.shared.detection("ChimeDetector started", platform: .chime)
    }

    func stop() {
        _isEnabled.withLock { $0 = false }
        pollTimer?.cancel()
        pollTimer = nil
        DetectionLogger.shared.detection("ChimeDetector stopped", platform: .chime)
    }

    // MARK: - Network UDP Detection

    private func startNetworkPolling() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.pollNetworkConnections()
        }
        timer.resume()
        pollTimer = timer
    }

    private func pollNetworkConnections() {
        guard isEnabled else { return }
        let udpCount = Self.countChimeUDPSockets()
        let active = udpCount > Self.udpSocketThreshold

        let lastActive = _lastNetworkActive.withLock { old -> Bool in
            let was = old; old = active; return was
        }
        if active != lastActive {
            DetectionLogger.shared.detection(
                "Network UDP sockets=\(udpCount) active=\(active)",
                platform: .chime, signal: .networkUDP, active: active
            )
            let signal = MeetingSignal(
                platform: .chime,
                isActive: active,
                confidence: .high,
                source: .networkUDP,
                timestamp: Date()
            )
            onSignal(signal)
        }
    }

    static func countChimeUDPSockets() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // Amazon Chime's process name for lsof -c prefix matching
        process.arguments = ["-a", "-i", "UDP", "-n", "-P", "-c", "Amazon Chime"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return 0
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return 0 }
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        return max(0, lines.count - 1)
    }

    // MARK: - CGWindowList Detection

    func processWindowList(_ windows: [WindowInfo]) {
        guard isEnabled else { return }

        let active = windows.contains { window in
            window.ownerName == "Amazon Chime" &&
            window.windowName == "Amazon Chime: Meeting Controls"
        }

        let lastActive = _lastActive.withLock { old -> Bool in
            let was = old
            old = active
            return was
        }

        if active != lastActive {
            DetectionLogger.shared.detection(
                "Chime meeting window \(active ? "found" : "gone")",
                platform: .chime, signal: .cgWindowList, active: active
            )
            let signal = MeetingSignal(
                platform: .chime,
                isActive: active,
                confidence: .high,
                source: .cgWindowList,
                timestamp: Date()
            )
            onSignal(signal)
        }
    }
}
