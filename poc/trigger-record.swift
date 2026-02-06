#!/usr/bin/env swift
// POC: Trigger MacWhisper to start recording a specific app
// Usage: swift trigger-record.swift [teams|comet|zoom]
// Requires: Accessibility permission for Terminal/IDE

import ApplicationServices
import AppKit
import Foundation

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

func findElementByDescription(_ parent: AXUIElement, description: String, depth: Int = 0, maxDepth: Int = 10) -> AXUIElement? {
    guard depth <= maxDepth else { return nil }

    let desc: String = axAttribute(parent, kAXDescriptionAttribute) ?? ""
    if desc == description {
        return parent
    }

    let children = axArrayAttribute(parent, kAXChildrenAttribute)
    for child in children {
        if let found = findElementByDescription(child, description: description, depth: depth + 1, maxDepth: maxDepth) {
            return found
        }
    }
    return nil
}

// MARK: - Main

// Check accessibility
let trusted = AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
)
guard trusted else {
    print("ERROR: Accessibility permission not granted.")
    exit(1)
}

// Parse argument
let appName: String
if CommandLine.arguments.count > 1 {
    appName = CommandLine.arguments[1].lowercased()
} else {
    print("Usage: swift trigger-record.swift [teams|comet|zoom|slack|chime|facetime]")
    print("       swift trigger-record.swift stop")
    exit(0)
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

if appName == "stop" {
    // Find stop recording button
    let windows = axArrayAttribute(appElement, kAXWindowsAttribute)
    for window in windows {
        // Search for stop-related buttons
        for desc in ["Stop Recording", "Stop", "stop"] {
            if let stopButton = findElementByDescription(window, description: desc) {
                print("Found '\(desc)' button - clicking...")
                let result = AXUIElementPerformAction(stopButton, kAXPressAction as CFString)
                print(result == .success ? "SUCCESS: Stop recording triggered" : "FAILED: AXError \(result.rawValue)")
                exit(result == .success ? 0 : 1)
            }
        }
    }
    print("No stop button found. Searching full tree for anything stop-related...")

    // Broader search
    func searchForStop(_ element: AXUIElement, depth: Int = 0) {
        guard depth <= 8 else { return }
        let desc: String = (axAttribute(element, kAXDescriptionAttribute) ?? "").lowercased()
        let title: String = (axAttribute(element, kAXTitleAttribute) ?? "").lowercased()
        let role: String = axAttribute(element, kAXRoleAttribute) ?? "?"
        if desc.contains("stop") || title.contains("stop") {
            let displayDesc: String = axAttribute(element, kAXDescriptionAttribute) ?? ""
            let displayTitle: String = axAttribute(element, kAXTitleAttribute) ?? ""
            print("  Found: [\(role)] title=\"\(displayTitle)\" desc=\"\(displayDesc)\"")
        }
        for child in axArrayAttribute(element, kAXChildrenAttribute) {
            searchForStop(child, depth: depth + 1)
        }
    }
    for window in windows {
        searchForStop(window)
    }
    exit(1)

} else {
    // Map friendly names to MacWhisper button descriptions
    let descriptionMap: [String: String] = [
        "teams": "Record Teams",
        "comet": "Record Comet",
        "zoom": "Record Zoom",
        "slack": "Record Slack",
        "chime": "Record Chime",
        "facetime": "Record FaceTime",
        "chrome": "Record Chrome",
    ]

    guard let buttonDesc = descriptionMap[appName] else {
        print("ERROR: Unknown app '\(appName)'. Available: \(descriptionMap.keys.sorted().joined(separator: ", "))")
        exit(1)
    }

    print("Looking for button: \"\(buttonDesc)\"...")

    // Search all windows for the button
    let windows = axArrayAttribute(appElement, kAXWindowsAttribute)
    for (i, window) in windows.enumerated() {
        if let button = findElementByDescription(window, description: buttonDesc) {
            print("Found \"\(buttonDesc)\" in window \(i) - clicking...")
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            if result == .success {
                print("SUCCESS: \"\(buttonDesc)\" triggered (MacWhisper stayed in background: \(!macWhisper.isActive))")
            } else {
                print("FAILED: AXError \(result.rawValue)")
            }
            exit(result == .success ? 0 : 1)
        }
    }

    print("Button \"\(buttonDesc)\" not found in any window.")
    print("MacWhisper may not have a shortcut configured for '\(appName)'.")
    print()
    print("Available buttons found:")

    // List what IS available
    func listRecordButtons(_ element: AXUIElement, depth: Int = 0) {
        guard depth <= 8 else { return }
        let desc: String = axAttribute(element, kAXDescriptionAttribute) ?? ""
        let role: String = axAttribute(element, kAXRoleAttribute) ?? ""
        if role == "AXButton" && desc.hasPrefix("Record ") {
            print("  - \"\(desc)\"")
        }
        for child in axArrayAttribute(element, kAXChildrenAttribute) {
            listRecordButtons(child, depth: depth + 1)
        }
    }
    for window in windows {
        listRecordButtons(window)
    }
    exit(1)
}
