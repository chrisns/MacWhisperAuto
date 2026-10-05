import ApplicationServices
import Foundation

extension MacWhisperController {
    /// All System Audio recording, used for FaceTime (no FaceTime item in the
    /// Record Meeting submenu) and the manual "System" button.
    ///
    /// MacWhisper has exposed this two ways:
    ///   1. Older builds: a "Record All System Audio" button in the main window.
    ///   2. 15.3+: an "App Audio" button that opens an "App Audio Recording"
    ///      view. In it, pick the "All System Audio" source, then press
    ///      "Start Recording".
    func performStartSystemAudioRecording(
        appElement: AXUIElement
    ) -> Result<Void, AXError> {
        DetectionLogger.shared.automation(
            "Navigating to All System Audio recording", action: "startRecording"
        )

        let windows = AccessibilityHelper.arrayAttribute(appElement, kAXWindowsAttribute)
        if windows.contains(where: Self.windowHasActiveStopButton) {
            DetectionLogger.shared.automation(
                "In-window Stop button present — MacWhisper is genuinely recording, no-op",
                action: "startRecording"
            )
            return .success(())
        }

        // Layout 1: legacy single button.
        for window in windows {
            for description in ["Record All System Audio", "All System Audio"] {
                guard let button = AccessibilityHelper.findByDescription(
                    window, description: description
                ) else { continue }
                let result = AccessibilityHelper.press(button)
                if case .success = result {
                    DetectionLogger.shared.automation(
                        "Recording started for All System Audio via '\(description)'",
                        action: "startRecording"
                    )
                }
                return result
            }
        }

        // Layout 2: App Audio view. Use it directly when the window already
        // shows it. Otherwise press App Audio, which is only on the Home view,
        // so switch the window to Home when it shows a transcript instead.
        for window in windows where AccessibilityHelper.findByDescription(
            window, description: "Start Recording", maxDepth: 12
        ) != nil {
            return startSystemAudioViaAppAudioView(window: window, appAudioButton: nil)
        }
        for window in windows {
            guard let appAudio = findAppAudioButton(in: window) else { continue }
            return startSystemAudioViaAppAudioView(window: window, appAudioButton: appAudio)
        }

        return .failure(
            .elementNotFound(description: "Record All System Audio / App Audio")
        )
    }

    private func findAppAudioButton(in window: AXUIElement) -> AXUIElement? {
        if let button = AccessibilityHelper.findByDescription(
            window, description: "App Audio", maxDepth: 12
        ) {
            return button
        }
        guard let home = AccessibilityHelper.findByDescription(
            window, description: "Home", maxDepth: 12
        ) else { return nil }
        DetectionLogger.shared.automation(
            "App Audio not visible, switching MacWhisper to Home", action: "startRecording"
        )
        // Sidebar items ignore AXPress; selecting their outline row navigates.
        guard let row = Self.ancestor(of: home, role: kAXRowRole),
              AXUIElementSetAttributeValue(
                row, kAXSelectedAttribute as CFString, kCFBooleanTrue
              ) == .success else { return nil }
        Thread.sleep(forTimeInterval: 0.7)
        return AccessibilityHelper.findByDescription(window, description: "App Audio", maxDepth: 12)
    }

    private static func ancestor(of element: AXUIElement, role: String, maxLevels: Int = 4) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<maxLevels {
            guard let node = current else { return nil }
            if (AccessibilityHelper.attribute(node, kAXRoleAttribute) as String?) == role { return node }
            current = AccessibilityHelper.attribute(node, kAXParentAttribute)
        }
        return nil
    }

    private func startSystemAudioViaAppAudioView(
        window: AXUIElement, appAudioButton: AXUIElement?
    ) -> Result<Void, AXError> {
        if let appAudioButton {
            DetectionLogger.shared.automation("Opening App Audio view", action: "startRecording")
            if case .failure(let error) = AccessibilityHelper.press(appAudioButton) {
                return .failure(error)
            }
            Thread.sleep(forTimeInterval: 0.7)
        }

        // The source list labels the current choice "Selected: All System Audio, ...".
        guard let source = AccessibilityHelper.findByDescriptionMatching(window, predicate: { desc in
            desc == "All System Audio" || desc.hasPrefix("Selected: All System Audio")
        }) else {
            return .failure(.elementNotFound(description: "App Audio > All System Audio"))
        }
        let sourceDesc: String = AccessibilityHelper.attribute(source, kAXDescriptionAttribute) ?? ""
        if !sourceDesc.hasPrefix("Selected:") {
            DetectionLogger.shared.automation(
                "Selecting All System Audio source", action: "startRecording"
            )
            if case .failure(let error) = AccessibilityHelper.press(source) {
                return .failure(error)
            }
            Thread.sleep(forTimeInterval: 0.3)
        }

        guard let start = AccessibilityHelper.findByDescription(
            window, description: "Start Recording", maxDepth: 12
        ) else {
            return .failure(.elementNotFound(description: "App Audio > Start Recording"))
        }
        let help: String = AccessibilityHelper.attribute(start, kAXHelpAttribute) ?? ""
        if !help.contains("System Audio") {
            DetectionLogger.shared.automation(
                "Start Recording help is '\(help)', expected System Audio — pressing anyway",
                action: "startRecording"
            )
        }
        let result = AccessibilityHelper.press(start)
        if case .success = result {
            DetectionLogger.shared.automation(
                "Recording started for All System Audio via App Audio view",
                action: "startRecording"
            )
        }
        return result
    }
}
