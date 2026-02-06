#!/usr/bin/env swift
// POC: Dump MacWhisper's accessibility tree to understand what's clickable
// Usage: swift dump-ax-tree.swift
// Requires: Accessibility permission for Terminal/IDE in System Settings > Privacy & Security > Accessibility

import ApplicationServices
import AppKit

// MARK: - Helpers

func axAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success else { return nil }
    return value as? T
}

func axArrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return (value as? [AXUIElement]) ?? []
}

func axActionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    AXUIElementCopyActionNames(element, &names)
    return (names as? [String]) ?? []
}

// MARK: - Tree dump

func dumpElement(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 6) {
    guard depth <= maxDepth else { return }

    let indent = String(repeating: "  ", count: depth)
    let role: String = axAttribute(element, kAXRoleAttribute) ?? "?"
    let subrole: String = axAttribute(element, kAXSubroleAttribute) ?? ""
    let title: String = axAttribute(element, kAXTitleAttribute) ?? ""
    let desc: String = axAttribute(element, kAXDescriptionAttribute) ?? ""
    let value: String = {
        if let v: String = axAttribute(element, kAXValueAttribute) { return v }
        if let v: Int = axAttribute(element, kAXValueAttribute) { return "\(v)" }
        return ""
    }()
    let enabled: Bool = axAttribute(element, kAXEnabledAttribute) ?? true
    let actions = axActionNames(element)

    var parts: [String] = ["\(indent)[\(role)]"]
    if !subrole.isEmpty { parts.append("subrole=\(subrole)") }
    if !title.isEmpty { parts.append("title=\"\(title)\"") }
    if !desc.isEmpty { parts.append("desc=\"\(desc)\"") }
    if !value.isEmpty && value.count < 100 { parts.append("value=\"\(value)\"") }
    if !enabled { parts.append("DISABLED") }
    if !actions.isEmpty { parts.append("actions=\(actions)") }

    print(parts.joined(separator: " "))

    let children = axArrayAttribute(element, kAXChildrenAttribute)
    for child in children {
        dumpElement(child, depth: depth + 1, maxDepth: maxDepth)
    }
}

// MARK: - Main

// Check accessibility permission
let trusted = AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
)
if !trusted {
    print("ERROR: Accessibility permission not granted.")
    print("Grant permission in System Settings > Privacy & Security > Accessibility")
    print("Then re-run this script.")
    exit(1)
}

// Find MacWhisper
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.goodsnooze.MacWhisper").first else {
    print("ERROR: MacWhisper is not running.")
    exit(1)
}

let pid = app.processIdentifier
print("Found MacWhisper (PID: \(pid))")
print("Is frontmost: \(app.isActive)")
print("Is hidden: \(app.isHidden)")
print()

let appElement = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(appElement, 5.0)

// Dump windows
print("=== WINDOWS ===")
let windows = axArrayAttribute(appElement, kAXWindowsAttribute)
print("Window count: \(windows.count)")
for (i, window) in windows.enumerated() {
    print("\n--- Window \(i) ---")
    dumpElement(window, maxDepth: 4)
}

// Dump menu bar
print("\n=== MENU BAR ===")
if let menuBar: AXUIElement = axAttribute(appElement, kAXMenuBarAttribute) {
    dumpElement(menuBar, maxDepth: 3)
} else {
    print("No menu bar found")
}

// Dump extras menu bar (status bar items)
print("\n=== EXTRAS MENU BAR ===")
if let extrasMenuBar: AXUIElement = axAttribute(appElement, kAXExtrasMenuBarAttribute) {
    dumpElement(extrasMenuBar, maxDepth: 3)
} else {
    print("No extras menu bar found")
}

// Search for anything with "record" or "meeting" in title/description
print("\n=== SEARCHING FOR RECORD/MEETING ELEMENTS ===")
func searchElement(_ element: AXUIElement, depth: Int = 0) {
    guard depth <= 8 else { return }

    let title: String = (axAttribute(element, kAXTitleAttribute) ?? "").lowercased()
    let desc: String = (axAttribute(element, kAXDescriptionAttribute) ?? "").lowercased()
    let role: String = axAttribute(element, kAXRoleAttribute) ?? "?"
    let actions = axActionNames(element)

    let keywords = ["record", "meeting", "teams", "zoom", "comet", "slack", "chime", "facetime", "stop", "start"]
    let matches = keywords.contains { title.contains($0) || desc.contains($0) }

    if matches {
        let indent = String(repeating: "  ", count: depth)
        let displayTitle: String = axAttribute(element, kAXTitleAttribute) ?? ""
        let displayDesc: String = axAttribute(element, kAXDescriptionAttribute) ?? ""
        print("\(indent)MATCH: [\(role)] title=\"\(displayTitle)\" desc=\"\(displayDesc)\" actions=\(actions)")
    }

    let children = axArrayAttribute(element, kAXChildrenAttribute)
    for child in children {
        searchElement(child, depth: depth + 1)
    }
}

// Search all windows
for window in windows {
    searchElement(window)
}

// Search menu bar
if let menuBar: AXUIElement = axAttribute(appElement, kAXMenuBarAttribute) {
    searchElement(menuBar)
}

print("\nDone.")
