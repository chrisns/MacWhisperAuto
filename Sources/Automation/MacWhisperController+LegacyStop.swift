import ApplicationServices
import Foundation

/// Legacy stop-recording helpers for older MacWhisper versions that surface a
/// "Finish Recording?" dialog triggered by clicking the active recording row in
/// the sidebar. Current MacWhisper exposes a top-level "Stop Recording" item in
/// its status-menu extra instead; these are kept as a fallback.
extension MacWhisperController {
    func pressFinishDialogButton(_ appElement: AXUIElement) -> Result<Void, AXError>? {
        let windows = AccessibilityHelper.arrayAttribute(appElement, kAXWindowsAttribute)
        for window in windows {
            let subrole: String? = AccessibilityHelper.attribute(window, kAXSubroleAttribute)
            guard subrole == "AXSystemDialog" else { continue }

            if let finishButton = AccessibilityHelper.findByDescription(
                window, description: "Finish"
            ) {
                let result = AccessibilityHelper.press(finishButton)
                switch result {
                case .success:
                    DetectionLogger.shared.automation(
                        "Recording stopped via Finish button", action: "stopRecording"
                    )
                case .failure(let error):
                    DetectionLogger.shared.error(
                        .automation, "Failed to press Finish: \(error)"
                    )
                }
                return result
            }
        }
        return nil
    }

    /// Find the active recording row in the sidebar (the cell containing "Meeting - ..." text).
    func findActiveRecordingRow(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 15 else { return nil }
        let role: String = AccessibilityHelper.attribute(element, kAXRoleAttribute) ?? ""
        if role == "AXCell" {
            for child in AccessibilityHelper.arrayAttribute(element, kAXChildrenAttribute) {
                let value: String = AccessibilityHelper.attribute(child, kAXValueAttribute) ?? ""
                if value.hasPrefix("Meeting") {
                    return element
                }
            }
        }
        for child in AccessibilityHelper.arrayAttribute(element, kAXChildrenAttribute) {
            if let found = findActiveRecordingRow(child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }
}
