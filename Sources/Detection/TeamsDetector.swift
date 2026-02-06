import CoreAudio
import Foundation
import IOKit.pwr_mgt
import os

/// Detects Microsoft Teams meetings via four complementary signals:
/// 1. CoreAudio: "Microsoft Teams Audio" virtual device running state (event-driven, instant)
/// 2. IOPMAssertion: "Microsoft Teams Call in progress" power assertion (polled every 3s)
/// 3. CGWindowList: Teams meeting window title pattern (polled every 3s via CGWindowListScanner)
/// 4. Network UDP: Count of UDP sockets for Teams process (polled every 3s, no permissions needed)
///
/// Signal 4 is the most reliable — during a call Teams opens 10+ UDP sockets for RTP/SRTP
/// media streams. Idle state has only 1 UDP listener. Requires no special permissions.
final class TeamsDetector: MeetingDetector, WindowListConsumer, @unchecked Sendable {
    private let onSignal: @Sendable (MeetingSignal) -> Void

    // CoreAudio state
    private let audioQueue = DispatchQueue(label: "com.macwhisperauto.teams.audio")
    private var teamsAudioDeviceID: AudioDeviceID?
    private var listenerInstalled = false

    // IOPM polling
    private var pollTimer: DispatchSourceTimer?
    private static let pollInterval: TimeInterval = 3.0
    private static let teamsAssertionName = "Microsoft Teams Call in progress"
    private static let teamsAudioDeviceName = "Microsoft Teams Audio"
    private let _lastIOPMActive = OSAllocatedUnfairLock(initialState: false)

    // CGWindowList state
    private let _lastWindowActive = OSAllocatedUnfairLock(initialState: false)

    // Network UDP state
    private let _lastNetworkActive = OSAllocatedUnfairLock(initialState: false)
    /// Idle Teams has ~1 UDP socket (listener on *:50070). During calls, 10+ appear.
    private static let udpSocketThreshold = 3

    /// Teams tab prefixes that indicate the main app window, NOT a meeting.
    private static let nonMeetingPrefixes = [
        "Chat |", "Calendar |", "Activity |", "Teams |", "Assignments |",
        "Files |", "Apps |", "Calls |", "Settings |", "People |",
        "OneDrive |", "Planner |", "Shifts |", "Approvals |",
    ]

    private let _isEnabled = OSAllocatedUnfairLock(initialState: true)
    var isEnabled: Bool { _isEnabled.withLock { $0 } }

    init(onSignal: @escaping @Sendable (MeetingSignal) -> Void) {
        self.onSignal = onSignal
    }

    deinit {
        stop()
    }

    func start() {
        _isEnabled.withLock { $0 = true }
        startCoreAudioListener()
        startIOPMPolling()
        DetectionLogger.shared.detection("TeamsDetector started", platform: .teams)
    }

    func stop() {
        _isEnabled.withLock { $0 = false }
        stopCoreAudioListener()
        stopIOPMPolling()
        DetectionLogger.shared.detection("TeamsDetector stopped", platform: .teams)
    }

    // MARK: - CoreAudio: Teams Audio Virtual Device

    private func startCoreAudioListener() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            guard let deviceID = self.findTeamsAudioDevice() else {
                DetectionLogger.shared.detection(
                    "Teams Audio virtual device not found (Teams may not be running)",
                    platform: .teams, signal: .coreAudio
                )
                return
            }
            self.teamsAudioDeviceID = deviceID
            self.installPropertyListener(on: deviceID)

            // Check initial state
            let running = self.isDeviceRunning(deviceID)
            DetectionLogger.shared.detection(
                "Teams Audio device \(deviceID) initial running=\(running)",
                platform: .teams, signal: .coreAudio, active: running
            )
            if running {
                self.emitSignal(active: true, source: .coreAudio, confidence: .high)
            }
        }
    }

    private func stopCoreAudioListener() {
        audioQueue.sync { [weak self] in
            guard let self, let deviceID = self.teamsAudioDeviceID, self.listenerInstalled else { return }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListener(deviceID, &address, audioPropertyListener, Unmanaged.passUnretained(self).toOpaque())
            self.listenerInstalled = false
            self.teamsAudioDeviceID = nil
        }
    }

    /// Find the "Microsoft Teams Audio" virtual device by name.
    private func findTeamsAudioDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return nil }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else { return nil }

        for deviceID in deviceIDs {
            if let name = deviceName(for: deviceID), name == Self.teamsAudioDeviceName {
                return deviceID
            }
        }
        return nil
    }

    private func deviceName(for deviceID: AudioDeviceID) -> String? {
        // Use the C-string property to avoid CFString/UnsafeMutableRawPointer warnings
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return nil }

        // kAudioObjectPropertyName returns a CFString bridged through the property system
        var nameUnmanaged: Unmanaged<CFString>?
        dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = withUnsafeMutablePointer(to: &nameUnmanaged) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr, let cfName = nameUnmanaged?.takeRetainedValue() else { return nil }
        return cfName as String
    }

    private func installPropertyListener(on deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListener(
            deviceID, &address, audioPropertyListener, Unmanaged.passUnretained(self).toOpaque()
        )
        if status == noErr {
            listenerInstalled = true
            DetectionLogger.shared.detection(
                "Installed CoreAudio listener on Teams Audio device \(deviceID)",
                platform: .teams, signal: .coreAudio
            )
        } else {
            DetectionLogger.shared.error(.detection,
                "Failed to install CoreAudio listener: OSStatus \(status)")
        }
    }

    private func isDeviceRunning(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &isRunning)
        guard status == noErr else { return false }
        return isRunning != 0
    }

    /// Called from CoreAudio's callback thread via the C function below.
    fileprivate func handleAudioPropertyChange() {
        guard let deviceID = teamsAudioDeviceID else { return }
        let running = isDeviceRunning(deviceID)
        DetectionLogger.shared.detection(
            "Teams Audio device running=\(running)",
            platform: .teams, signal: .coreAudio, active: running
        )
        emitSignal(active: running, source: .coreAudio, confidence: .high)
    }

    // MARK: - IOPMAssertion Polling

    private func startIOPMPolling() {
        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        timer.schedule(
            deadline: .now(),
            repeating: Self.pollInterval,
            leeway: .milliseconds(500)
        )
        timer.setEventHandler { [weak self] in
            self?.pollIOPMAssertions()
            self?.pollNetworkConnections()
        }
        timer.resume()
        pollTimer = timer
    }

    private func stopIOPMPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func pollIOPMAssertions() {
        let active = Self.isTeamsCallAssertionPresent()
        let lastActive = _lastIOPMActive.withLock { old -> Bool in
            let was = old; old = active; return was
        }
        // Only log and emit on state change to avoid flooding
        if active != lastActive {
            DetectionLogger.shared.detection(
                "IOPM assertion active=\(active)",
                platform: .teams, signal: .iopmAssertion, active: active
            )
            emitSignal(active: active, source: .iopmAssertion, confidence: .high)
        }
    }

    /// Check if Teams has created a "Microsoft Teams Call in progress" power assertion.
    static func isTeamsCallAssertionPresent() -> Bool {
        var assertionsByProcess: Unmanaged<CFDictionary>?
        IOPMCopyAssertionsByProcess(&assertionsByProcess)
        guard let dict = assertionsByProcess?.takeRetainedValue() as? [String: [[String: Any]]] else {
            return false
        }
        for (_, assertions) in dict {
            for assertion in assertions {
                if let name = assertion["AssertName"] as? String,
                   name == teamsAssertionName {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Network UDP: Media Socket Detection

    private func pollNetworkConnections() {
        let udpCount = Self.countTeamsUDPSockets()
        let active = udpCount > Self.udpSocketThreshold

        let lastActive = _lastNetworkActive.withLock { old -> Bool in
            let was = old; old = active; return was
        }
        if active != lastActive {
            DetectionLogger.shared.detection(
                "Network UDP sockets=\(udpCount) active=\(active)",
                platform: .teams, signal: .networkUDP, active: active
            )
            emitSignal(active: active, source: .networkUDP, confidence: .high)
        }
    }

    /// Count UDP sockets owned by the MSTeams process.
    /// Idle: ~1 (listener *:50070). During calls: 10+ (RTP/SRTP media streams).
    static func countTeamsUDPSockets() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-i", "UDP", "-n", "-P", "-c", "MSTeams"]
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
        // First line is header ("COMMAND PID USER ..."), rest are socket entries
        return max(0, lines.count - 1)
    }

    // MARK: - CGWindowList: Meeting Window Title Detection

    func processWindowList(_ windows: [WindowInfo]) {
        guard isEnabled else { return }

        let teamsWindows = windows.filter { $0.ownerName == "Microsoft Teams" && !$0.windowName.isEmpty }
        let active = teamsWindows.contains { window in
            guard window.windowName.hasSuffix("| Microsoft Teams") else {
                return false
            }
            // Exclude main app windows (Chat, Calendar, etc.)
            return !Self.nonMeetingPrefixes.contains { prefix in
                window.windowName.hasPrefix(prefix)
            }
        }

        // Log Teams windows for debugging (only when there are interesting windows)
        if !teamsWindows.isEmpty {
            let titles = teamsWindows.map { $0.windowName }
            DetectionLogger.shared.detection(
                "Teams windows: \(titles), meeting=\(active)",
                platform: .teams, signal: .cgWindowList, active: active
            )
        }

        let lastActive = _lastWindowActive.withLock { old -> Bool in
            let was = old
            old = active
            return was
        }

        // Only emit on state change to avoid flooding the state machine
        if active != lastActive {
            DetectionLogger.shared.detection(
                "Teams meeting window \(active ? "found" : "gone")",
                platform: .teams, signal: .cgWindowList, active: active
            )
            emitSignal(active: active, source: .cgWindowList, confidence: .high)
        }
    }

    // MARK: - Signal Emission

    private func emitSignal(active: Bool, source: SignalSource, confidence: SignalConfidence) {
        guard isEnabled else { return }
        let signal = MeetingSignal(
            platform: .teams,
            isActive: active,
            confidence: confidence,
            source: source,
            timestamp: Date()
        )
        onSignal(signal)
    }
}

// MARK: - CoreAudio C Property Listener Callback

/// C-function callback required by AudioObjectAddPropertyListener.
/// The `clientData` pointer is an unretained reference to the TeamsDetector instance.
private func audioPropertyListener(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let detector = Unmanaged<TeamsDetector>.fromOpaque(clientData).takeUnretainedValue()
    detector.handleAudioPropertyChange()
    return noErr
}
