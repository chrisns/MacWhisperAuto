import ApplicationServices
import Foundation

/// Navigation inside MacWhisper's main window.
extension MacWhisperController {
    /// Find a Home-view control (Record buttons, App Audio) by AXDescription.
    /// When the window shows another view, select the sidebar's Home row and
    /// look again. Sidebar items ignore AXPress; selecting their row navigates.
    static func findOnHomeView(_ window: AXUIElement, description: String) -> AXUIElement? {
        if let element = AccessibilityHelper.findByDescription(
            window, description: description, maxDepth: 12
        ) {
            return element
        }
        guard let home = AccessibilityHelper.findByDescription(
            window, description: "Home", maxDepth: 12
        ), let row = ancestor(of: home, role: kAXRowRole) else { return nil }
        DetectionLogger.shared.automation(
            "'\(description)' not visible, switching MacWhisper to Home", action: "startRecording"
        )
        guard AXUIElementSetAttributeValue(
            row, kAXSelectedAttribute as CFString, kCFBooleanTrue
        ) == .success else { return nil }
        Thread.sleep(forTimeInterval: 0.7)
        return AccessibilityHelper.findByDescription(window, description: description, maxDepth: 12)
    }

    static func ancestor(of element: AXUIElement, role: String, maxLevels: Int = 4) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<maxLevels {
            guard let node = current else { return nil }
            if (AccessibilityHelper.attribute(node, kAXRoleAttribute) as String?) == role { return node }
            current = AccessibilityHelper.attribute(node, kAXParentAttribute)
        }
        return nil
    }
}
