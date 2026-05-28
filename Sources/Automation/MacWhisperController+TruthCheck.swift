import ApplicationServices
import Foundation

/// Passive AX read helpers used by `performCheckRecording` to combine two
/// independent signals into a conservative "is MacWhisper recording" answer.
extension MacWhisperController {
    /// Does MacWhisper's status-menu extra contain a recording indicator?
    /// Passive read — no menu open required. Can lag/lie briefly after a stop,
    /// which is why we pair it with `anyWindowHasActiveStopButton`.
    func menuExtraShowsRecording(_ appElement: AXUIElement) -> Bool {
        guard let extras: AXUIElement =
                AccessibilityHelper.attribute(appElement, kAXExtrasMenuBarAttribute),
              let menuExtra = AccessibilityHelper.arrayAttribute(
                extras, kAXChildrenAttribute
              ).first else {
            return false
        }
        return AccessibilityHelper.findMenuItemMatching(
            menuExtra, maxDepth: 4
        ) { title in
            if title == "Stop Recording" { return true }
            return title.lowercased().hasPrefix("recording ")
        } != nil
    }

    /// Does any MacWhisper window expose the in-progress Stop button? The
    /// button only exists while MacWhisper is actively recording, so this is
    /// the ground-truth signal.
    func anyWindowHasActiveStopButton(_ appElement: AXUIElement) -> Bool {
        let windows = AccessibilityHelper.arrayAttribute(appElement, kAXWindowsAttribute)
        for window in windows where Self.windowHasActiveStopButton(window) {
            return true
        }
        return false
    }
}
