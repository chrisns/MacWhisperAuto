import ApplicationServices
import Foundation

enum AccessibilityHelper {

    /// Get AX attribute value.
    static func attribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? T
    }

    /// Get array attribute (children, windows, etc.).
    static func arrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (value as? [AXUIElement]) ?? []
    }

    /// Press/click an element via AXPress action.
    static func press(_ element: AXUIElement) -> Result<Void, AXError> {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if result == .success {
            return .success(())
        }
        let role: String = attribute(element, kAXRoleAttribute) ?? "unknown"
        let desc: String = attribute(element, kAXDescriptionAttribute)
            ?? attribute(element, kAXTitleAttribute)
            ?? "unknown"
        return .failure(.actionFailed(
            element: "\(role):\(desc)", action: "AXPress", code: result.rawValue
        ))
    }

    /// Recursive tree search by AXDescription (exact match).
    static func findByDescription(
        _ parent: AXUIElement,
        description: String,
        maxDepth: Int = 10,
        currentDepth: Int = 0
    ) -> AXUIElement? {
        guard currentDepth <= maxDepth else { return nil }
        let desc: String = attribute(parent, kAXDescriptionAttribute) ?? ""
        if desc == description { return parent }
        for child in arrayAttribute(parent, kAXChildrenAttribute) {
            if let found = findByDescription(
                child, description: description,
                maxDepth: maxDepth, currentDepth: currentDepth + 1
            ) {
                return found
            }
        }
        return nil
    }

    /// Recursive search for AXMenuItem by exact title.
    static func findMenuItemByTitle(
        _ parent: AXUIElement,
        title: String,
        maxDepth: Int = 6,
        currentDepth: Int = 0
    ) -> AXUIElement? {
        guard currentDepth <= maxDepth else { return nil }
        let role: String = attribute(parent, kAXRoleAttribute) ?? ""
        let itemTitle: String = attribute(parent, kAXTitleAttribute) ?? ""
        if role == "AXMenuItem" && itemTitle == title { return parent }
        for child in arrayAttribute(parent, kAXChildrenAttribute) {
            if let found = findMenuItemByTitle(
                child, title: title,
                maxDepth: maxDepth, currentDepth: currentDepth + 1
            ) {
                return found
            }
        }
        return nil
    }

    /// Recursive search for AXMenuItem by title. Tries exact match first,
    /// then falls back to case-insensitive `contains` so subtle renames
    /// (e.g. "Teams" → "Microsoft Teams") still resolve.
    static func findMenuItemByFuzzyTitle(
        _ parent: AXUIElement,
        title: String,
        maxDepth: Int = 6
    ) -> AXUIElement? {
        if let exact = findMenuItemByTitle(parent, title: title, maxDepth: maxDepth) {
            return exact
        }
        let needle = title.lowercased()
        return findMenuItemMatching(parent, maxDepth: maxDepth) { itemTitle in
            itemTitle.lowercased().contains(needle)
        }
    }

    /// Recursive search for AXMenuItem whose title satisfies a predicate.
    static func findMenuItemMatching(
        _ parent: AXUIElement,
        maxDepth: Int = 6,
        currentDepth: Int = 0,
        predicate: (String) -> Bool
    ) -> AXUIElement? {
        guard currentDepth <= maxDepth else { return nil }
        let role: String = attribute(parent, kAXRoleAttribute) ?? ""
        let itemTitle: String = attribute(parent, kAXTitleAttribute) ?? ""
        if role == "AXMenuItem" && !itemTitle.isEmpty && predicate(itemTitle) {
            return parent
        }
        for child in arrayAttribute(parent, kAXChildrenAttribute) {
            if let found = findMenuItemMatching(
                child, maxDepth: maxDepth,
                currentDepth: currentDepth + 1,
                predicate: predicate
            ) {
                return found
            }
        }
        return nil
    }

    /// Collect all non-empty AXMenuItem titles under the given element.
    static func enumerateMenuItemTitles(
        _ parent: AXUIElement,
        maxDepth: Int = 4,
        currentDepth: Int = 0
    ) -> [String] {
        guard currentDepth <= maxDepth else { return [] }
        var titles: [String] = []
        let role: String = attribute(parent, kAXRoleAttribute) ?? ""
        if role == "AXMenuItem" {
            let title: String = attribute(parent, kAXTitleAttribute) ?? ""
            if !title.isEmpty {
                titles.append(title)
            }
        }
        for child in arrayAttribute(parent, kAXChildrenAttribute) {
            titles.append(contentsOf: enumerateMenuItemTitles(
                child, maxDepth: maxDepth, currentDepth: currentDepth + 1
            ))
        }
        return titles
    }

    /// Recursive search for AXMenuItem whose title starts with a prefix
    /// (e.g. "Recording" for "Recording 00:03:42").
    static func findMenuItemWithTitlePrefix(
        _ parent: AXUIElement,
        prefix: String,
        maxDepth: Int = 6,
        currentDepth: Int = 0
    ) -> AXUIElement? {
        guard currentDepth <= maxDepth else { return nil }
        let role: String = attribute(parent, kAXRoleAttribute) ?? ""
        let itemTitle: String = attribute(parent, kAXTitleAttribute) ?? ""
        if role == "AXMenuItem" && itemTitle.hasPrefix(prefix) { return parent }
        for child in arrayAttribute(parent, kAXChildrenAttribute) {
            if let found = findMenuItemWithTitlePrefix(
                child, prefix: prefix,
                maxDepth: maxDepth, currentDepth: currentDepth + 1
            ) {
                return found
            }
        }
        return nil
    }
}
