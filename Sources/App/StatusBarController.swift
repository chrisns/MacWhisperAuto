import AppKit
import SwiftUI

@MainActor
final class StatusBarController {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let appState: AppState
    private let permissionManager: PermissionManager
    private var iconTimer: Timer?

    // Actions (set by AppDelegate)
    var onForceQuitRelaunch: (() -> Void)?
    var onRetry: (() -> Void)?
    var onManualRecord: ((String) -> Void)?
    var onStopRecording: (() -> Void)?

    init(appState: AppState, permissionManager: PermissionManager) {
        self.appState = appState
        self.permissionManager = permissionManager
        setupStatusItem()
        setupPopover()
        startObservingState()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "mic.circle",
                accessibilityDescription: "MacWhisperAuto"
            )
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 400)
        popover.behavior = .transient
        popover.contentViewController = makePopoverContent()
    }

    private func makePopoverContent() -> NSHostingController<AnyView> {
        if appState.showOnboarding {
            return NSHostingController(
                rootView: AnyView(OnboardingView(permissionManager: permissionManager))
            )
        } else {
            return NSHostingController(
                rootView: AnyView(StatusMenuView(
                    appState: appState,
                    onForceQuitRelaunch: onForceQuitRelaunch,
                    onRetry: onRetry,
                    onManualRecord: onManualRecord,
                    onStopRecording: onStopRecording
                ))
            )
        }
    }

    private func startObservingState() {
        iconTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateIcon()
            }
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbolName: String
        switch appState.meetingState {
        case .idle:
            symbolName = appState.permissionsGranted ? "mic.circle" : "exclamationmark.triangle"
        case .detecting:
            symbolName = "mic.badge.xmark"
        case .recording:
            symbolName = "record.circle.fill"
        case .error:
            symbolName = "exclamationmark.triangle"
        }
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "MacWhisperAuto - \(appState.statusDescription)"
        )
        button.image?.isTemplate = true
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Refresh content to reflect current permission state
            popover.contentViewController = makePopoverContent()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
