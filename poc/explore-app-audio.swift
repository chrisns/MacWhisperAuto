#!/usr/bin/env swift
// Deep exploration of MacWhisper's accessibility tree
// Focus: App Audio workflow, All System Audio, Start Recording
// DOES NOT CLICK ANYTHING - read-only exploration
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
func axActionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    AXUIElementCopyActionNames(element, &names)
    return (names as? [String]) ?? []
}
func axAttributeNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    AXUIElementCopyAttributeNames(element, &names)
    return (names as? [String]) ?? []
}
func axPosition(_ element: AXUIElement) -> CGPoint? {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)
    guard err == .success, let val = value else { return nil }
    var point = CGPoint.zero
    AXValueGetValue(val as! AXValue, .cgPoint, &point)
    return point
}
func axSize(_ element: AXUIElement) -> CGSize? {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
    guard err == .success, let val = value else { return nil }
    var size = CGSize.zero
    AXValueGetValue(val as! AXValue, .cgSize, &size)
    return size
}

// ── Section 1: Full filtered tree dump ──
func dumpElement(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 15) {
    guard depth <= maxDepth else { return }
    let indent = String(repeating: "  ", count: depth)
    let role: String = axAttribute(element, kAXRoleAttribute) ?? "?"
    let subrole: String = axAttribute(element, kAXSubroleAttribute) ?? ""
    let title: String = axAttribute(element, kAXTitleAttribute) ?? ""
    let desc: String = axAttribute(element, kAXDescriptionAttribute) ?? ""
    let value: String = {
        if let v: String = axAttribute(element, kAXValueAttribute) { return v }
        if let v: Int = axAttribute(element, kAXValueAttribute) { return "\(v)" }
        if let v: NSNumber = axAttribute(element, kAXValueAttribute) { return "\(v)" }
        return ""
    }()
    let identifier: String = axAttribute(element, "AXIdentifier") ?? ""
    let enabled: Bool = axAttribute(element, kAXEnabledAttribute) ?? true
    let actions = axActionNames(element)
    let pos = axPosition(element)
    let sz = axSize(element)

    let isInteresting = !title.isEmpty || !desc.isEmpty || !identifier.isEmpty ||
        ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
         "AXTabGroup", "AXTab", "AXGrid", "AXTable", "AXList", "AXTextField",
         "AXStaticText", "AXImage", "AXToggle", "AXSwitch", "AXDisclosureTriangle",
         "AXOutline", "AXScrollArea", "AXToolbar", "AXSegmentedControl",
         "AXPopover", "AXSheet", "AXDialog"].contains(role)

    if isInteresting {
        var parts: [String] = ["\(indent)[\(role)]"]
        if !subrole.isEmpty { parts.append("sub=\(subrole)") }
        if !title.isEmpty { parts.append("title=\"\(title)\"") }
        if !desc.isEmpty { parts.append("desc=\"\(desc)\"") }
        if !value.isEmpty && value.count < 80 { parts.append("val=\"\(value)\"") }
        if !identifier.isEmpty { parts.append("id=\"\(identifier)\"") }
        if !enabled { parts.append("DISABLED") }
        if !actions.isEmpty && actions.count <= 5 { parts.append("actions=\(actions)") }
        if let p = pos, let s = sz { parts.append("@(\(Int(p.x)),\(Int(p.y))) \(Int(s.width))x\(Int(s.height))") }
        print(parts.joined(separator: " "))
    }

    for child in axArrayAttribute(element, kAXChildrenAttribute) {
        dumpElement(child, depth: depth + 1, maxDepth: maxDepth)
    }
}

// ── Section 2: Targeted keyword search ──
func searchElement(_ element: AXUIElement, keywords: [String], depth: Int = 0, maxDepth: Int = 15, path: [String] = []) {
    guard depth <= maxDepth else { return }
    let role: String = axAttribute(element, kAXRoleAttribute) ?? "?"
    let title: String = axAttribute(element, kAXTitleAttribute) ?? ""
    let desc: String = axAttribute(element, kAXDescriptionAttribute) ?? ""
    let value: String = {
        if let v: String = axAttribute(element, kAXValueAttribute) { return v }
        return ""
    }()
    let identifier: String = axAttribute(element, "AXIdentifier") ?? ""
    let actions = axActionNames(element)

    let allText = "\(title) \(desc) \(value) \(identifier)".lowercased()
    let matchedKeywords = keywords.filter { allText.contains($0) }

    if !matchedKeywords.isEmpty {
        let indent = String(repeating: "  ", count: depth)
        let pos = axPosition(element)
        let sz = axSize(element)
        var parts: [String] = ["\(indent)MATCH[\(matchedKeywords.joined(separator: ","))]"]
        parts.append("[\(role)]")
        if !title.isEmpty { parts.append("title=\"\(title)\"") }
        if !desc.isEmpty { parts.append("desc=\"\(desc)\"") }
        if !value.isEmpty && value.count < 80 { parts.append("val=\"\(value)\"") }
        if !identifier.isEmpty { parts.append("id=\"\(identifier)\"") }
        if !actions.isEmpty { parts.append("actions=\(actions)") }
        if let p = pos, let s = sz { parts.append("@(\(Int(p.x)),\(Int(p.y))) \(Int(s.width))x\(Int(s.height))") }
        // Print the path to this element
        if !path.isEmpty {
            parts.append("path=[\(path.joined(separator: " > "))]")
        }
        print(parts.joined(separator: " "))
    }

    let currentLabel = "\(role)"
        + (title.isEmpty ? "" : "(\(title))")
        + (desc.isEmpty ? "" : "(\(desc))")

    for child in axArrayAttribute(element, kAXChildrenAttribute) {
        searchElement(child, keywords: keywords, depth: depth + 1, maxDepth: maxDepth, path: path + [currentLabel])
    }
}

// ── Section 3: Detailed attribute dump for a specific element ──
func detailedDump(_ element: AXUIElement, label: String) {
    print("\n  --- Detailed: \(label) ---")
    let attrs = axAttributeNames(element)
    for attr in attrs.sorted() {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        if err == .success, let v = value {
            let typeID = CFGetTypeID(v)
            if typeID == CFStringGetTypeID() {
                print("    \(attr) = \"\(v as! CFString)\"")
            } else if typeID == CFBooleanGetTypeID() {
                print("    \(attr) = \(CFBooleanGetValue(v as! CFBoolean))")
            } else if typeID == CFNumberGetTypeID() {
                print("    \(attr) = \(v)")
            } else if typeID == CFArrayGetTypeID() {
                let arr = v as! CFArray as! [Any]
                print("    \(attr) = [Array count=\(arr.count)]")
            } else if typeID == AXValueGetTypeID() {
                let axVal = v as! AXValue
                let axType = AXValueGetType(axVal)
                if axType == .cgPoint {
                    var pt = CGPoint.zero
                    AXValueGetValue(axVal, .cgPoint, &pt)
                    print("    \(attr) = CGPoint(\(pt.x), \(pt.y))")
                } else if axType == .cgSize {
                    var sz = CGSize.zero
                    AXValueGetValue(axVal, .cgSize, &sz)
                    print("    \(attr) = CGSize(\(sz.width), \(sz.height))")
                } else if axType == .cgRect {
                    var r = CGRect.zero
                    AXValueGetValue(axVal, .cgRect, &r)
                    print("    \(attr) = CGRect(\(r))")
                } else {
                    print("    \(attr) = AXValue(type=\(axType.rawValue))")
                }
            } else {
                print("    \(attr) = <\(CFCopyTypeIDDescription(typeID) ?? "unknown" as CFString)>")
            }
        }
    }
    let actions = axActionNames(element)
    print("    actions = \(actions)")
}

// ── Section 4: Find specific element and dump its neighborhood ──
func findElement(_ parent: AXUIElement, role: String? = nil, desc: String? = nil, title: String? = nil, depth: Int = 0, maxDepth: Int = 15) -> AXUIElement? {
    guard depth <= maxDepth else { return nil }
    let eRole: String = axAttribute(parent, kAXRoleAttribute) ?? ""
    let eDesc: String = axAttribute(parent, kAXDescriptionAttribute) ?? ""
    let eTitle: String = axAttribute(parent, kAXTitleAttribute) ?? ""
    let roleMatch = role == nil || eRole == role
    let descMatch = desc == nil || eDesc.lowercased().contains(desc!.lowercased())
    let titleMatch = title == nil || eTitle.lowercased().contains(title!.lowercased())
    if roleMatch && descMatch && titleMatch {
        return parent
    }
    for child in axArrayAttribute(parent, kAXChildrenAttribute) {
        if let found = findElement(child, role: role, desc: desc, title: title, depth: depth + 1, maxDepth: maxDepth) {
            return found
        }
    }
    return nil
}

func findAllElements(_ parent: AXUIElement, role: String? = nil, desc: String? = nil, title: String? = nil, depth: Int = 0, maxDepth: Int = 15) -> [AXUIElement] {
    guard depth <= maxDepth else { return [] }
    var results: [AXUIElement] = []
    let eRole: String = axAttribute(parent, kAXRoleAttribute) ?? ""
    let eDesc: String = axAttribute(parent, kAXDescriptionAttribute) ?? ""
    let eTitle: String = axAttribute(parent, kAXTitleAttribute) ?? ""
    let roleMatch = role == nil || eRole == role
    let descMatch = desc == nil || eDesc.lowercased().contains(desc!.lowercased())
    let titleMatch = title == nil || eTitle.lowercased().contains(title!.lowercased())
    if roleMatch && descMatch && titleMatch {
        results.append(parent)
    }
    for child in axArrayAttribute(parent, kAXChildrenAttribute) {
        results += findAllElements(child, role: role, desc: desc, title: title, depth: depth + 1, maxDepth: maxDepth)
    }
    return results
}

// ══════════════════════════════════════════════
// MAIN
// ══════════════════════════════════════════════

let trusted = AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
)
guard trusted else { print("ERROR: No accessibility permission"); exit(1) }

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.goodsnooze.MacWhisper").first else {
    print("ERROR: MacWhisper not running"); exit(1)
}

let appEl = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(appEl, 5.0)

let windows = axArrayAttribute(appEl, kAXWindowsAttribute)
print("══════════════════════════════════════════════════")
print("  MacWhisper Deep AX Exploration (READ-ONLY)")
print("  PID: \(app.processIdentifier) | Windows: \(windows.count)")
print("══════════════════════════════════════════════════")

// ── Part A: Full filtered tree for each window ──
print("\n╔══ PART A: FULL FILTERED TREE ══╗")
for (i, w) in windows.enumerated() {
    let wTitle: String = axAttribute(w, kAXTitleAttribute) ?? "(untitled)"
    let wPos = axPosition(w)
    let wSz = axSize(w)
    print("\n┌─ Window \(i): \"\(wTitle)\"", terminator: "")
    if let p = wPos, let s = wSz { print(" @(\(Int(p.x)),\(Int(p.y))) \(Int(s.width))x\(Int(s.height))", terminator: "") }
    print(" ─┐")
    dumpElement(w, maxDepth: 12)
}

// ── Part B: Keyword search ──
print("\n╔══ PART B: KEYWORD SEARCH ══╗")
let keywords = ["app audio", "system audio", "all system", "start record", "stop record",
                 "record micro", "facetime", "microphone", "toggle", "tab",
                 "navigation", "sidebar", "segment"]
print("Keywords: \(keywords)")
for w in windows {
    searchElement(w, keywords: keywords)
}

// Also search menu bar
print("\n── Menu bar keyword search ──")
if let menuBar: AXUIElement = axAttribute(appEl, kAXMenuBarAttribute) {
    searchElement(menuBar, keywords: keywords)
}

// ── Part C: Detailed look at "App Audio" button ──
print("\n╔══ PART C: 'APP AUDIO' BUTTON DETAIL ══╗")
for w in windows {
    if let appAudioBtn = findElement(w, desc: "app audio") {
        detailedDump(appAudioBtn, label: "App Audio button")

        // Also look at parent/siblings
        if let parent: AXUIElement = axAttribute(appAudioBtn, "AXParent") {
            let parentRole: String = axAttribute(parent, kAXRoleAttribute) ?? "?"
            let parentTitle: String = axAttribute(parent, kAXTitleAttribute) ?? ""
            print("\n  Parent: [\(parentRole)] title=\"\(parentTitle)\"")
            let siblings = axArrayAttribute(parent, kAXChildrenAttribute)
            print("  Siblings (\(siblings.count)):")
            for (si, sib) in siblings.enumerated() {
                let sRole: String = axAttribute(sib, kAXRoleAttribute) ?? "?"
                let sTitle: String = axAttribute(sib, kAXTitleAttribute) ?? ""
                let sDesc: String = axAttribute(sib, kAXDescriptionAttribute) ?? ""
                let sPos = axPosition(sib)
                let sSz = axSize(sib)
                var info = "    [\(si)] [\(sRole)]"
                if !sTitle.isEmpty { info += " title=\"\(sTitle)\"" }
                if !sDesc.isEmpty { info += " desc=\"\(sDesc)\"" }
                if let p = sPos, let s = sSz { info += " @(\(Int(p.x)),\(Int(p.y))) \(Int(s.width))x\(Int(s.height))" }
                print(info)
            }
        }
    } else {
        // Try title-based search
        if let appAudioBtn = findElement(w, title: "app audio") {
            detailedDump(appAudioBtn, label: "App Audio (title match)")
        }
    }
}

// ── Part D: All buttons in the app ──
print("\n╔══ PART D: ALL BUTTONS ══╗")
for w in windows {
    let buttons = findAllElements(w, role: "AXButton")
    print("Total buttons: \(buttons.count)")
    for btn in buttons {
        let title: String = axAttribute(btn, kAXTitleAttribute) ?? ""
        let desc: String = axAttribute(btn, kAXDescriptionAttribute) ?? ""
        let identifier: String = axAttribute(btn, "AXIdentifier") ?? ""
        let pos = axPosition(btn)
        let sz = axSize(btn)
        let enabled: Bool = axAttribute(btn, kAXEnabledAttribute) ?? true
        var info = "  [AXButton]"
        if !title.isEmpty { info += " title=\"\(title)\"" }
        if !desc.isEmpty { info += " desc=\"\(desc)\"" }
        if !identifier.isEmpty { info += " id=\"\(identifier)\"" }
        if !enabled { info += " DISABLED" }
        if let p = pos, let s = sz { info += " @(\(Int(p.x)),\(Int(p.y))) \(Int(s.width))x\(Int(s.height))" }
        print(info)
    }
}

// ── Part E: All checkboxes/toggles/switches ──
print("\n╔══ PART E: ALL CHECKBOXES/TOGGLES ══╗")
for w in windows {
    for roleToFind in ["AXCheckBox", "AXSwitch", "AXToggle", "AXRadioButton"] {
        let elements = findAllElements(w, role: roleToFind)
        if !elements.isEmpty {
            print("  \(roleToFind) (\(elements.count)):")
            for el in elements {
                let title: String = axAttribute(el, kAXTitleAttribute) ?? ""
                let desc: String = axAttribute(el, kAXDescriptionAttribute) ?? ""
                let val: String = {
                    if let v: String = axAttribute(el, kAXValueAttribute) { return v }
                    if let v: NSNumber = axAttribute(el, kAXValueAttribute) { return "\(v)" }
                    return ""
                }()
                let pos = axPosition(el)
                var info = "    [\(roleToFind)]"
                if !title.isEmpty { info += " title=\"\(title)\"" }
                if !desc.isEmpty { info += " desc=\"\(desc)\"" }
                if !val.isEmpty { info += " val=\"\(val)\"" }
                if let p = pos { info += " @(\(Int(p.x)),\(Int(p.y)))" }
                print(info)
            }
        }
    }
}

// ── Part F: All static text ──
print("\n╔══ PART F: ALL STATIC TEXT ══╗")
for w in windows {
    let texts = findAllElements(w, role: "AXStaticText")
    print("Total static texts: \(texts.count)")
    for t in texts {
        let val: String = axAttribute(t, kAXValueAttribute) ?? ""
        let title: String = axAttribute(t, kAXTitleAttribute) ?? ""
        let pos = axPosition(t)
        let sz = axSize(t)
        let display = !val.isEmpty ? val : title
        if !display.isEmpty {
            var info = "  \"\(display)\""
            if let p = pos, let s = sz { info += " @(\(Int(p.x)),\(Int(p.y))) \(Int(s.width))x\(Int(s.height))" }
            print(info)
        }
    }
}

// ── Part G: All popups/popovers/sheets/dialogs ──
print("\n╔══ PART G: POPUPS/POPOVERS/SHEETS/DIALOGS ══╗")
for w in windows {
    for roleToFind in ["AXPopover", "AXSheet", "AXDialog", "AXPopUpButton", "AXMenuButton"] {
        let elements = findAllElements(w, role: roleToFind)
        if !elements.isEmpty {
            print("  \(roleToFind) (\(elements.count)):")
            for el in elements {
                let title: String = axAttribute(el, kAXTitleAttribute) ?? ""
                let desc: String = axAttribute(el, kAXDescriptionAttribute) ?? ""
                let val: String = {
                    if let v: String = axAttribute(el, kAXValueAttribute) { return v }
                    return ""
                }()
                let pos = axPosition(el)
                var info = "    [\(roleToFind)]"
                if !title.isEmpty { info += " title=\"\(title)\"" }
                if !desc.isEmpty { info += " desc=\"\(desc)\"" }
                if !val.isEmpty { info += " val=\"\(val)\"" }
                if let p = pos { info += " @(\(Int(p.x)),\(Int(p.y)))" }
                print(info)
            }
        }
    }
}

// ── Part H: Full menu bar dump with deeper exploration ──
print("\n╔══ PART H: MENU BAR (depth=5) ══╗")
if let menuBar: AXUIElement = axAttribute(appEl, kAXMenuBarAttribute) {
    dumpElement(menuBar, maxDepth: 5)
}

// ── Part I: Check for any windows we might be missing (sheets, panels) ──
print("\n╔══ PART I: OTHER WINDOW-LIKE ELEMENTS ══╗")
// Try focused window
if let focusedWindow: AXUIElement = axAttribute(appEl, kAXFocusedWindowAttribute) {
    let title: String = axAttribute(focusedWindow, kAXTitleAttribute) ?? "(untitled)"
    print("Focused window: \"\(title)\"")
}
// Try main window
if let mainWindow: AXUIElement = axAttribute(appEl, kAXMainWindowAttribute) {
    let title: String = axAttribute(mainWindow, kAXTitleAttribute) ?? "(untitled)"
    print("Main window: \"\(title)\"")
}

// ── Part J: Search for "Record" prefixed descriptions ──
print("\n╔══ PART J: ALL 'RECORD' ELEMENTS ══╗")
for w in windows {
    searchElement(w, keywords: ["record"])
}

// ── Part K: Look for tab-like navigation ──
print("\n╔══ PART K: TAB/SEGMENTED/TOOLBAR ELEMENTS ══╗")
for w in windows {
    for roleToFind in ["AXTabGroup", "AXTab", "AXSegmentedControl", "AXToolbar"] {
        let elements = findAllElements(w, role: roleToFind)
        if !elements.isEmpty {
            print("  \(roleToFind) (\(elements.count)):")
            for el in elements {
                detailedDump(el, label: roleToFind)
                // Show immediate children
                let children = axArrayAttribute(el, kAXChildrenAttribute)
                print("    Children (\(children.count)):")
                for (ci, c) in children.enumerated() {
                    let cRole: String = axAttribute(c, kAXRoleAttribute) ?? "?"
                    let cTitle: String = axAttribute(c, kAXTitleAttribute) ?? ""
                    let cDesc: String = axAttribute(c, kAXDescriptionAttribute) ?? ""
                    print("      [\(ci)] [\(cRole)] title=\"\(cTitle)\" desc=\"\(cDesc)\"")
                }
            }
        }
    }
}

print("\n══════════════════════════════════════════════════")
print("  Exploration complete. No actions were performed.")
print("══════════════════════════════════════════════════")
