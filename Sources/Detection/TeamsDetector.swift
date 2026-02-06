import CoreAudio
import Foundation
import IOKit.pwr_mgt
import os

/// Detects Microsoft Teams meetings via two complementary signals:
/// 1. CoreAudio: "Microsoft Teams Audio" virtual device running state (event-driven, instant)
/// 2. IOPMAssertion: "Microsoft Teams Call in progress" power assertion (polled every 3s)
///
/// Neither signal requires any user permission.
final class TeamsDetector: MeetingDetector, @unchecked Sendable {
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
        DetectionLogger.shared.detection(
            "IOPM assertion poll active=\(active)",
            platform: .teams, signal: .iopmAssertion, active: active
        )
        emitSignal(active: active, source: .iopmAssertion, confidence: .high)
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
