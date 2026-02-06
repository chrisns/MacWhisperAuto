import CoreGraphics
import Foundation

/// Represents a window from CGWindowListCopyWindowInfo.
struct WindowInfo: Sendable {
    let ownerName: String
    let ownerPID: Int32
    let windowName: String
    let windowLayer: Int
    let bounds: CGRect
}

/// Protocol for detectors that consume CGWindowList data.
/// Detectors register with CGWindowListScanner and receive window snapshots each poll cycle.
protocol WindowListConsumer: AnyObject, Sendable {
    /// Called on the scanner's polling queue with the full window list.
    /// The consumer should filter for its relevant windows and emit signals.
    func processWindowList(_ windows: [WindowInfo])
}

/// Polls CGWindowListCopyWindowInfo on a 3-second interval and distributes the result
/// to registered consumers. Only polls when the AppMonitor reports relevant apps running.
///
/// Single CGWindowList call per cycle serves all detectors (NFR2).
/// Completes in <2ms with .optionOnScreenOnly (NFR1).
final class CGWindowListScanner: @unchecked Sendable {
    private let pollQueue = DispatchQueue(label: "com.macwhisperauto.windowlist")
    private var pollTimer: DispatchSourceTimer?
    private static let pollInterval: TimeInterval = 3.0

    private let _consumers = OSAllocatedUnfairLock(initialState: [WeakConsumer]())
    private let _shouldPoll = OSAllocatedUnfairLock(initialState: true)

    /// Set to false to suppress polling (e.g. no relevant apps running).
    var shouldPoll: Bool {
        get { _shouldPoll.withLock { $0 } }
        set { _shouldPoll.withLock { $0 = newValue } }
    }

    func registerConsumer(_ consumer: any WindowListConsumer) {
        _consumers.withLock { consumers in
            consumers.append(WeakConsumer(consumer))
        }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(
            deadline: .now(),
            repeating: Self.pollInterval,
            leeway: .milliseconds(500)
        )
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        pollTimer = timer
        DetectionLogger.shared.detection("CGWindowListScanner started (interval=\(Self.pollInterval)s)")
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        DetectionLogger.shared.detection("CGWindowListScanner stopped")
    }

    /// Force an immediate poll (e.g. after wake from sleep).
    func pollNow() {
        pollQueue.async { [weak self] in
            self?.poll()
        }
    }

    // MARK: - Private

    private func poll() {
        guard shouldPoll else { return }

        let windows = captureWindowList()

        // Distribute to consumers, pruning dead weak refs
        let consumers = _consumers.withLock { list -> [any WindowListConsumer] in
            list.removeAll { $0.value == nil }
            return list.compactMap(\.value)
        }

        for consumer in consumers {
            consumer.processWindowList(windows)
        }
    }

    /// Single CGWindowList call per cycle - <2ms with .optionOnScreenOnly.
    private func captureWindowList() -> [WindowInfo] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return windowList.compactMap { dict -> WindowInfo? in
            guard let ownerName = dict[kCGWindowOwnerName as String] as? String,
                  let ownerPID = dict[kCGWindowOwnerPID as String] as? Int32 else {
                return nil
            }
            let windowName = dict[kCGWindowName as String] as? String ?? ""
            let layer = dict[kCGWindowLayer as String] as? Int ?? 0

            var bounds = CGRect.zero
            if let boundsDict = dict[kCGWindowBounds as String] as? [String: Any] {
                let x = boundsDict["X"] as? CGFloat ?? 0
                let y = boundsDict["Y"] as? CGFloat ?? 0
                let w = boundsDict["Width"] as? CGFloat ?? 0
                let h = boundsDict["Height"] as? CGFloat ?? 0
                bounds = CGRect(x: x, y: y, width: w, height: h)
            }

            return WindowInfo(
                ownerName: ownerName,
                ownerPID: ownerPID,
                windowName: windowName,
                windowLayer: layer,
                bounds: bounds
            )
        }
    }
}

// MARK: - Weak reference wrapper

private final class WeakConsumer: @unchecked Sendable {
    weak var value: (any WindowListConsumer)?
    init(_ value: any WindowListConsumer) {
        self.value = value
    }
}

import os
