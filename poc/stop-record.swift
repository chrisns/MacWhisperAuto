#!/usr/bin/env swift
// POC: Stop MacWhisper recording via menu bar "Stop Recording" menu item
// Usage: swift stop-record.swift

import ApplicationServices
import AppKit
import Foundation

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

func findMenuItemByTitle(_ parent: AXUIElement, title: String, depth: Int = 0) -> AXUIElement? {
    guard depth <= 6 else { return nil }

    let role: String = axAttribute(parent, kAXRoleAttribute) ?? ""
    let itemTitle: String = axAttribute(parent, kAXTitleAttribute) ?? ""

    if role == "AXMenuItem" && itemTitle == title {
        return parent
    }

    let children = axArrayAttribute(parent, kAXChildrenAttribute)
    for child in children {
        if let found = findMenuItemByTitle(child, title: title, depth: depth + 1) {
            return found
        }
    }
    return nil
}

// Check accessibility
let trusted = AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
)
guard trusted else {
    print("ERROR: Accessibility permission not granted.")
    exit(1)
}

// Find MacWhisper
guard let macWhisper = NSRunningApplication.runningApplications(withBundleIdentifier: "com.goodsnooze.MacWhisper").first else {
    print("ERROR: MacWhisper is not running.")
    exit(1)
}

let pid = macWhisper.processIdentifier
let appElement = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(appElement, 5.0)

print("MacWhisper found (PID: \(pid), frontmost: \(macWhisper.isActive))")

// Search the menu bar for "Stop Recording"
guard let menuBar: AXUIElement = axAttribute(appElement, kAXMenuBarAttribute) else {
    print("ERROR: No menu bar found")
    exit(1)
}

if let stopItem = findMenuItemByTitle(menuBar, title: "Stop Recording") {
    print("Found 'Stop Recording' menu item - clicking...")
    let result = AXUIElementPerformAction(stopItem, kAXPressAction as CFString)
    if result == .success {
        print("SUCCESS: Stop Recording triggered (MacWhisper stayed in background: \(!macWhisper.isActive))")
    } else {
        print("FAILED: AXError \(result.rawValue)")
    }
    exit(result == .success ? 0 : 1)
} else {
    print("'Stop Recording' menu item not found. MacWhisper may not be recording.")

    // Check what IS in the menu bar
    print("\nMenu bar items found:")
    func listMenuItems(_ element: AXUIElement, depth: Int = 0) {
        guard depth <= 4 else { return }
        let role: String = axAttribute(element, kAXRoleAttribute) ?? ""
        let title: String = axAttribute(element, kAXTitleAttribute) ?? ""
        if role == "AXMenuItem" && !title.isEmpty {
            print("  - \"\(title)\"")
        }
        for child in axArrayAttribute(element, kAXChildrenAttribute) {
            listMenuItems(child, depth: depth + 1)
        }
    }
    listMenuItems(menuBar)
    exit(1)
}
