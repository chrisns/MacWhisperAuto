import ApplicationServices
import Foundation

extension MacWhisperController {
    /// FaceTime fallback: MacWhisper has no FaceTime item in the Record Meeting
    /// submenu, so press the "Record All System Audio" button in the main window.
    func performStartFaceTimeRecording(
        appElement: AXUIElement
    ) -> Result<Void, AXError> {
        DetectionLogger.shared.automation(
            "FaceTime: navigating to All System Audio fallback", action: "startRecording"
        )

        let candidates = ["Record All System Audio", "All System Audio"]
        let windows = AccessibilityHelper.arrayAttribute(appElement, kAXWindowsAttribute)
        for window in windows {
            for description in candidates {
                guard let button = AccessibilityHelper.findByDescription(
                    window, description: description
                ) else { continue }
                let result = AccessibilityHelper.press(button)
                if case .success = result {
                    DetectionLogger.shared.automation(
                        "Recording started for FaceTime (All System Audio)",
                        action: "startRecording"
                    )
                }
                return result
            }
        }
        return .failure(
            .elementNotFound(description: "Record All System Audio / All System Audio")
        )
    }
}
