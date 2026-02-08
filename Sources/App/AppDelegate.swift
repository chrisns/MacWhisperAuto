import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusBarController: StatusBarController?
    private var coordinator: DetectionCoordinator?
    private let macWhisperController = InjectedMacWhisperController()
    private let permissionManager = PermissionManager()
    private var appMonitor: AppMonitor?
    private var windowScanner: CGWindowListScanner?
    private var permissionCheckTimer: DispatchSourceTimer?
    private var webSocketServer: WebSocketServer?
    private var extensionMessageHandler: ExtensionMessageHandler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DetectionLogger.shared.lifecycle("Application launched")

        // Check permissions and update app state
        checkPermissions()

        // Wire up the detection pipeline
        let stateMachine = MeetingStateMachine()
        let coord = DetectionCoordinator(stateMachine: stateMachine, appState: appState)
        coordinator = coord

        // Wire side effects to MacWhisper automation
        coord.onStartRecording = { [weak self] platform in
            self?.handleStartRecording(platform: platform)
        }
        coord.onStopRecording = { [weak self] in
            self?.handleStopRecording()
        }

        // Register detectors
        let signalHandler: @Sendable (MeetingSignal) -> Void = { [weak coord] signal in
            coord?.handleSignal(signal)
        }
        let teamsDetector = TeamsDetector(onSignal: signalHandler)
        let zoomDetector = ZoomDetector(onSignal: signalHandler)
        let slackDetector = SlackDetector(onSignal: signalHandler)
        let chimeDetector = ChimeDetector(onSignal: signalHandler)
        let faceTimeDetector = FaceTimeDetector(onSignal: signalHandler)

        coord.registerDetector(teamsDetector)
        coord.registerDetector(zoomDetector)
        coord.registerDetector(slackDetector)
        coord.registerDetector(chimeDetector)
        coord.registerDetector(faceTimeDetector)

        // Set up app monitoring and CGWindowList polling
        let monitor = AppMonitor()
        let scanner = CGWindowListScanner()
        scanner.registerConsumer(teamsDetector)
        scanner.registerConsumer(zoomDetector)
        scanner.registerConsumer(slackDetector)
        scanner.registerConsumer(chimeDetector)
        scanner.registerConsumer(faceTimeDetector)
        monitor.onChange = { [weak scanner] platforms in
            scanner?.shouldPoll = !platforms.isEmpty
        }
        scanner.shouldPoll = monitor.hasRelevantApps
        appMonitor = monitor
        windowScanner = scanner

        // Always start detection - it only needs Screen Recording (for CGWindowList).
        // Accessibility is only needed for MacWhisper automation (start/stop recording).
        coord.start()
        monitor.start()
        scanner.start()
        DetectionLogger.shared.lifecycle("Detection started")
        appState.addActivity("Detection started")

        // Set up WebSocket server for browser extension
        let messageHandler = ExtensionMessageHandler(
            onSignal: { [weak coord] signal in
                coord?.handleSignal(signal)
            },
            onConnectionStateChanged: { [weak appState] connected in
                Task { @MainActor in
                    appState?.extensionConnected = connected
                }
            }
        )
        extensionMessageHandler = messageHandler

        let wsServer = WebSocketServer()
        wsServer.onMessage = { [weak messageHandler] data in
            messageHandler?.handleMessage(data)
        }
        wsServer.onClientConnected = { [weak messageHandler] in
            messageHandler?.onConnectionStateChanged(true)
        }
        wsServer.onClientDisconnected = { [weak wsServer, weak appState] in
            let stillConnected = wsServer?.hasConnections ?? false
            Task { @MainActor in
                appState?.extensionConnected = stillConnected
            }
        }
        wsServer.onError = { [weak appState] error in
            Task { @MainActor in
                // WebSocket failure is non-fatal - native detection still works
                DetectionLogger.shared.error(.webSocket, "WebSocket error: \(error)")
                appState?.addActivity("Browser extension unavailable (WebSocket error)")
            }
        }
        webSocketServer = wsServer
        wsServer.start()

        // Set up menu bar UI (pass permissionManager for onboarding)
        let sbc = StatusBarController(
            appState: appState,
            permissionManager: permissionManager
        )
        sbc.onForceQuitRelaunch = { [weak self] in
            self?.handleForceQuitRelaunch()
        }
        sbc.onRetry = { [weak self] in
            self?.handleRetry()
        }
        statusBarController = sbc

        // System notifications for sleep/wake and app termination
        registerForSystemNotifications()

        // Register as login item
        registerLoginItem()

        // Start periodic permission monitoring (Story 2.2)
        startPermissionPolling()

        // Prepare injection environment in background (compile dylib, copy+resign MacWhisper)
        // so it's ready when a meeting is first detected.
        macWhisperController.prepareInBackground()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DetectionLogger.shared.lifecycle("Application terminating")
        permissionCheckTimer?.cancel()
        permissionCheckTimer = nil
        webSocketServer?.stop()
        coordinator?.stop()
        appMonitor?.stop()
        windowScanner?.stop()
        unregisterFromSystemNotifications()
    }

    // MARK: - Permission Checking

    private func checkPermissions() {
        let perms = permissionManager.checkAll()
        let axGranted = perms[.accessibility] ?? false
        let srGranted = perms[.screenRecording] ?? false
        appState.permissionsGranted = axGranted && srGranted

        if axGranted {
            DetectionLogger.shared.permissions("Accessibility: granted")
        } else {
            DetectionLogger.shared.permissions("Accessibility: NOT granted")
        }
        if srGranted {
            DetectionLogger.shared.permissions("Screen Recording: granted")
        } else {
            DetectionLogger.shared.permissions("Screen Recording: NOT granted")
        }
    }

    /// Called periodically or after permission changes to re-evaluate and start detection.
    func recheckPermissionsAndStart() {
        checkPermissions()
        if appState.permissionsGranted {
            coordinator?.start()
            appMonitor?.start()
            windowScanner?.start()
            DetectionLogger.shared.lifecycle("Detection started after permissions granted")
            appState.addActivity("Detection started after permissions granted")
        }
    }

    // MARK: - Permission Polling (Story 2.2)

    private func startPermissionPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30.0, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            self?.checkPermissionsAndReport()
        }
        timer.resume()
        permissionCheckTimer = timer
    }

    private func checkPermissionsAndReport() {
        let wasGranted = appState.permissionsGranted
        checkPermissions()

        if wasGranted && !appState.permissionsGranted {
            // Permission was revoked
            let perms = permissionManager.checkAll()
            let axGranted = perms[.accessibility] ?? false
            let srGranted = perms[.screenRecording] ?? false
            if !axGranted {
                coordinator?.reportError(.permissionDenied(.accessibility))
                appState.addActivity("Accessibility permission revoked")
            }
            if !srGranted {
                coordinator?.reportError(.permissionDenied(.screenRecording))
                appState.addActivity("Screen Recording permission revoked")
            }
            coordinator?.stop()
        } else if !wasGranted && appState.permissionsGranted {
            // Permission was re-granted
            coordinator?.clearError()
            coordinator?.start()
            appMonitor?.start()
            windowScanner?.start()
            appState.addActivity("Permissions restored - detection resumed")
        }
    }

    // MARK: - Error Recovery

    private func handleForceQuitRelaunch() {
        DetectionLogger.shared.lifecycle("User requested force quit & relaunch of MacWhisper")
        appState.addActivity("Force quitting MacWhisper...")

        let ctrl = macWhisperController
        let coordRef = coordinator
        let stateRef = appState

        ctrl.forceQuitAndRelaunch { launched in
            Task { @MainActor in
                if launched {
                    coordRef?.clearError()
                    stateRef.addActivity("MacWhisper relaunched successfully")
                    // If a meeting is still active (detectors still running), the next signal
                    // will trigger recording again through the normal state machine flow
                } else {
                    stateRef.addActivity("MacWhisper relaunch failed")
                }
            }
        }
    }

    private func handleRetry() {
        DetectionLogger.shared.lifecycle("User requested error retry")
        coordinator?.clearError()
        appState.addActivity("Error cleared - resuming detection")
    }

    // MARK: - MacWhisper Automation (Side Effect Handlers)

    private func handleStartRecording(platform: Platform) {
        DetectionLogger.shared.automation(
            "Side effect: start recording \(platform.displayName)", action: "startRecording"
        )

        // Injection approach: no accessibility permission needed.
        // The controller handles prepare + launch + socket command internally.
        let controller = macWhisperController
        let coordRef = coordinator
        let stateRef = appState

        controller.launchIfNeeded { launched in
            Task { @MainActor in
                guard launched else {
                    coordRef?.reportError(.macWhisperNotRunning)
                    stateRef.addActivity("Failed to launch injectable MacWhisper", platform: platform)
                    return
                }
                let innerCoord = coordRef
                let innerState = stateRef
                controller.startRecording(for: platform) { result in
                    Task { @MainActor in
                        switch result {
                        case .success:
                            innerState.addActivity(
                                "Recording started for \(platform.displayName)", platform: platform
                            )
                        case .failure(let error):
                            DetectionLogger.shared.error(.automation, "Start recording failed: \(error)")
                            innerState.addActivity("Recording failed: \(error)", platform: platform)
                            switch error {
                            case .macWhisperNotRunning:
                                innerCoord?.reportError(.macWhisperNotRunning)
                            case .elementNotFound(let desc):
                                innerCoord?.reportError(.axElementNotFound(desc))
                            case .timeout:
                                innerCoord?.reportError(.macWhisperUnresponsive)
                            case .noPermission:
                                innerCoord?.reportError(.permissionDenied(.accessibility))
                            case .actionFailed:
                                innerCoord?.reportError(.macWhisperUnresponsive)
                            }
                        }
                    }
                }
            }
        }
    }

    private func handleStopRecording() {
        DetectionLogger.shared.automation("Side effect: stop recording", action: "stopRecording")

        // Injection approach: no accessibility permission needed.
        let controller = macWhisperController
        let stateRef = appState

        controller.stopRecording { result in
            Task { @MainActor in
                switch result {
                case .success:
                    stateRef.addActivity("Recording stopped")
                case .failure(let error):
                    DetectionLogger.shared.error(.automation, "Stop recording failed: \(error)")
                    stateRef.addActivity("Stop recording failed: \(error)")
                    // Don't transition to error on stop failure - recording may have already stopped
                }
            }
        }
    }

    // MARK: - Sleep / Wake / App Termination

    private func registerForSystemNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(handleSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleAppTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleAppLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
    }

    private func unregisterFromSystemNotifications() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func handleSleep(_ notification: Notification) {
        DetectionLogger.shared.lifecycle("System going to sleep - suspending detection")
        coordinator?.handleSleep()
        appState.addActivity("System sleep - detection suspended")
    }

    @objc private func handleWake(_ notification: Notification) {
        DetectionLogger.shared.lifecycle("System woke from sleep - resuming detection")
        appState.addActivity("System wake - resuming detection")

        // Re-check permissions (may have changed during sleep/update)
        checkPermissions()

        if appState.permissionsGranted {
            coordinator?.handleWake()
        }
    }

    @objc private func handleAppTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.goodsnooze.MacWhisper" else { return }
        // Distinguish between real and injectable MacWhisper
        let isInjectable = app.bundleURL?.path.contains("Injectable") == true
        DetectionLogger.shared.lifecycle(
            "\(isInjectable ? "Injectable " : "")MacWhisper terminated"
        )
        appState.addActivity("\(isInjectable ? "Injectable " : "")MacWhisper quit")

        // If we were recording, MacWhisper quitting is an error condition
        if appState.isRecording {
            coordinator?.reportError(.macWhisperNotRunning)
            appState.addActivity("MacWhisper quit during recording!")
        }
    }

    @objc private func handleAppLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.goodsnooze.MacWhisper" else { return }
        DetectionLogger.shared.lifecycle("MacWhisper launched")
        appState.addActivity("MacWhisper launched")

        // If we were in error state due to MacWhisper issues, clear it after a delay
        // to give MacWhisper time to become AX-accessible
        if case .error(let kind) = appState.meetingState {
            switch kind {
            case .macWhisperUnresponsive, .macWhisperNotRunning, .axElementNotFound:
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.coordinator?.clearError()
                    self?.appState.addActivity("MacWhisper recovered - detection resumed")
                }
            default:
                break
            }
        }
    }

    // MARK: - Login Item

    private func registerLoginItem() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            if service.status != .enabled {
                do {
                    try service.register()
                    DetectionLogger.shared.lifecycle("Registered as login item")
                } catch {
                    DetectionLogger.shared.error(.lifecycle,
                        "Failed to register login item: \(error.localizedDescription)")
                }
            }
        }
    }
}
