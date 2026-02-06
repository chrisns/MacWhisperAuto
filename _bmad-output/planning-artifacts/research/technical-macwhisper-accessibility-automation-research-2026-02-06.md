---
stepsCompleted: [1, 2, 3]
inputDocuments: []
workflowType: 'research'
lastStep: 3
research_type: 'technical'
research_topic: 'MacWhisper accessibility-based automation and macOS meeting detection'
research_goals: 'Determine how to programmatically control MacWhisper recording via accessibility APIs, and validate native app meeting detection approaches'
user_name: 'Cns'
date: '2026-02-06'
web_research_enabled: true
source_verification: true
---

# Research Report: Technical

**Date:** 2026-02-06
**Author:** Cns
**Research Type:** Technical
**Status:** COMPLETE - All research threads consolidated

---

## Table of Contents

1. [MacWhisper Reverse Engineering](#reverse-engineering-findings-macwhisperapp)
2. [MacWhisper Automation POC Results](#poc-results-macwhisper-automation-confirmed-working)
3. [MacWhisper UserDefaults & FaceTime Fallback](#macwhisper-userdefaults--facetime-fallback)
4. [Meeting Detection - Teams Native (Primary)](#teams-native-meeting-detection-primary-platform)
5. [Meeting Detection - Other Native Apps](#meeting-detection-other-native-apps)
6. [CoreAudio & Process-Level Mic Monitoring](#coreaudio--process-level-mic-monitoring)
7. [CGWindowList Window Title Scanning](#cgwindowlist-window-title-scanning)
8. [Host Application Architecture](#host-application-architecture)
9. [Browser Extension Architecture](#browser-extension-architecture)
10. [Recommended Detection Strategy](#recommended-detection-strategy)

---

## Reverse Engineering Findings: MacWhisper.app

### Application Identity
- **Bundle ID:** `com.goodsnooze.MacWhisper`
- **Developer:** Good Snooze (developer: ian, per Xcode DerivedData path in binary)
- **URL Scheme:** `macwhisper://` (only known path: `macwhisper://reopenWindow`)
- **AppleScript Dictionary:** None (no `.sdef` file, `NSAppleScriptEnabled` not set)
- **CLI Interface:** None
- **XPC Services:** Only Sparkle update framework XPC (not app-specific)

### MacWhisper's Built-in Meeting Detection (Broken)
MacWhisper already has meeting detection using `lsof` UDP connection counting:
```
lsof -i 4UDP +c0 | grep -E 'teams|MSTeams' | awk 'END{print NR}'
lsof -i 4UDP +c0 | grep -w zoom | awk 'END{print NR}'
lsof -i 4UDP +c0 | grep -w Amazon | awk 'END{print NR}'
lsof -i 4UDP +c0 | grep -E 'WebexHelp|Meeting\\x20Center' | awk 'END{print NR}'
```

**Why it fails:**
- Teams keeps UDP connections open even when idle (confirmed: MSTeams UDP on port 50070 while no meeting active)
- Browser-based meetings (Meet, Slack) show as Chrome/Comet process, not matching app-specific grep patterns
- UDP connections are ephemeral and point-in-time

### MacWhisper Internal Architecture (from binary strings)
- `ActiveMeetingDetectionManager` - detects meetings
- `MeetingRecordingCoordinator` - coordinates recording
- `_handleNotificationToStartRecordingApp` - in-process NSNotification handler (not cross-process)
- `_handleNotificationToStopRecordingApp` - in-process NSNotification handler
- `startRecordingMeeting(_:)` - takes an app parameter
- `stopRecordingMeeting()` - stops current meeting recording
- `RecordableAppsListManager` - manages recordable app list

### MacWhisper Current User Configuration
```
hasEnabledRecordMeetings = 1
autoDismissMeetingAlert = 0   (prompt stays until manually dismissed)
autoStartGlobal = 0
useCalendarForMeetings = 1
meetingAppsToObserve = [zoom, teams, slack, comet, whatsapp]
systemAudioRecordMicrophoneEnabled = 1
appVisibilityMode = both  (dock and menu bar)
```

---

## POC Results: MacWhisper Automation (CONFIRMED WORKING)

**Date:** 2026-02-06
**Status:** PROVEN - both start and stop recording work from background

### Start Recording
- **Element:** `[AXButton] desc="Record Teams"` (also "Record Comet", "Record Zoom", etc.)
- **Location:** Main window, home screen shortcut buttons
- **Action:** `AXUIElementPerformAction(button, kAXPressAction)`
- **Background:** YES - works without bringing MacWhisper to front
- **POC script:** `poc/trigger-record.swift`

### Stop Recording
- **Element:** `[AXMenuItem] title="Stop Recording"`
- **Location:** Extras menu bar (status bar dropdown via `kAXExtrasMenuBarAttribute`)
- **Action:** `AXUIElementPerformAction(menuItem, kAXPressAction)`
- **Background:** YES - works without bringing MacWhisper to front
- **POC script:** `poc/stop-record.swift`

### Check Recording Status
- **Element:** `[AXMenuItem] title="Recording Teams Meeting"` (disabled status indicator)
- **Location:** Extras menu bar (status bar dropdown)
- **Method:** Check if menu item with title starting with "Recording" exists

### Available Record Buttons (confirmed 2026-02-06)
```
[AXButton] desc="Record Comet"   actions=["AXScrollToVisible", "AXShowMenu", "AXPress"]
[AXButton] desc="Record Teams"   actions=["AXScrollToVisible", "AXShowMenu", "AXPress"]
[AXButton] desc="Record Zoom"    actions=["AXScrollToVisible", "AXShowMenu", "AXPress"]
[AXButton] desc="Record Slack"   actions=["AXScrollToVisible", "AXShowMenu", "AXPress"]
[AXButton] desc="Record Chime"   actions=["AXScrollToVisible", "AXShowMenu", "AXPress"]
[AXButton] desc="Record Chrome"  actions=["AXScrollToVisible", "AXShowMenu", "AXPress"]
```

### Permissions Required
- **Accessibility:** Must be granted to the host app in System Settings > Privacy & Security > Accessibility
- **No Screen Recording needed** for the MacWhisper automation itself

### Key Technical Notes
- MacWhisper is a SwiftUI app but its home screen buttons ARE in the accessibility tree even when not frontmost
- Status bar menu items are accessible via `kAXExtrasMenuBarAttribute` (not `kAXMenuBarAttribute`)
- `AXUIElementSetMessagingTimeout` should be set to avoid hangs if MacWhisper is busy
- Element descriptions use format "Record [AppName]" matching the shortcut button labels
- Always re-query elements before acting (references go stale)

---

## MacWhisper UserDefaults & FaceTime Fallback

### UserDefaults JSON Format (Reverse Engineered)

**`homeShortcuts` array** (controls Home screen buttons):
```json
[
  {"destination":{"_0":{"newVoiceMemo":{}}}},
  {"destination":{"_0":{"openFiles":{}}}},
  {"destination":{"_0":{"appAudio":{}}}},
  {"destination":{"_0":{"batch":{}}}},
  {"destination":{"_0":{"podcast":{}}}},
  {"destination":{"_0":{"manageModels":{}}}},
  {"recordMeeting":{"_0":{"other":{"_0":"comet"}}}},
  {"recordMeeting":{"_0":{"teams":{}}}},
  {"recordMeeting":{"_0":{"zoom":{}}}},
  {"recordMeeting":{"_0":{"other":{"_0":"slack"}}}},
  {"recordMeeting":{"_0":{"chime":{}}}},
  {"recordMeeting":{"_0":{"other":{"_0":"chrome"}}}}
]
```

**Pattern for custom apps:** `{"recordMeeting":{"_0":{"other":{"_0":"APP_NAME"}}}}`

**`meetingAppsToObserve` array:**
```json
[
  {"zoom":{}},
  {"teams":{}},
  {"other":{"_0":"slack"}},
  {"other":{"_0":"comet"}},
  {"other":{"_0":"whatsapp"}}
]
```

### FaceTime Limitation
- **FaceTime is NOT available as a per-app recording target** in MacWhisper
- MacWhisper cannot isolate FaceTime's audio stream (FaceTime uses system audio)
- No "Record FaceTime" button exists on the home screen

### FaceTime Fallback Options

**Option 1: Add FaceTime via UserDefaults (most promising)**
Append `{"other":{"_0":"facetime"}}` to both `homeShortcuts` and `meetingAppsToObserve`. Requires MacWhisper restart to pick up changes. May or may not work - MacWhisper may not be able to capture FaceTime audio per-app.

**Option 2: Multi-step AX Automation ("All System Audio")**
1. Press `[AXButton desc="App Audio"]` on home screen
2. Wait ~500ms for SwiftUI view transition
3. Re-scan AX tree for "All System Audio" button in the new view
4. Click "All System Audio"
5. Click "Start Recording"

**Fragility:** More fragile than one-click shortcuts. Each step requires waiting for SwiftUI view transitions. The AX tree structure inside App Audio is unknown until navigated to.

**Option 3: Combination signal**
Detect FaceTime + mic active → use "All System Audio" automation path. FaceTime calls are less frequent, so higher automation complexity is acceptable.

---

## Teams Native Meeting Detection (Primary Platform)

### Signal Summary

| Signal | Reliability | Permission | Latency | Method |
|--------|------------|-----------|---------|--------|
| **IOPMAssertion** | HIGH | None | ~2-3s (poll) | `IOPMCopyAssertionsByProcess()` |
| **"Microsoft Teams Audio" virtual device** | HIGH | None | Instant (event) | `AudioObjectAddPropertyListener` |
| **CGWindowList window titles** | MEDIUM | Screen Recording | ~3s (poll) | `CGWindowListCopyWindowInfo` |
| **AXObserver window events** | HIGH | Accessibility | Instant (event) | `kAXTitleChangedNotification` |
| **NSDistributedNotification** | NOT AVAILABLE | - | - | Teams doesn't use it |
| **Teams local server (port 8124)** | NOT AVAILABLE | - | - | Not a usable API |
| **powerd system log** | BROKEN on macOS 26 | - | - | `log show` returns nothing |
| **Old Teams logs.txt** | NOT AVAILABLE | - | - | Only for classic Teams |

### Signal 1: IOPMAssertion (PRIMARY - No Permission Required)

When a Teams call/meeting is active, Teams creates a power assertion:
```
"Microsoft Teams Call in progress"
```

**Detection via Swift API:**
```swift
import IOKit.pwr_mgt

func isTeamsCallActive() -> Bool {
    var assertionsByProcess: Unmanaged<CFDictionary>?
    IOPMCopyAssertionsByProcess(&assertionsByProcess)
    guard let dict = assertionsByProcess?.takeRetainedValue() as? [String: [[String: Any]]] else {
        return false
    }
    for (_, assertions) in dict {
        for assertion in assertions {
            if let name = assertion["AssertName"] as? String,
               name == "Microsoft Teams Call in progress" {
                return true
            }
        }
    }
    return false
}
```

**CRITICAL:** The `log show --process powerd` approach (used by TeamsStatusMacOS) is **BROKEN on macOS 26 Tahoe**. Zero powerd entries found over 30-day log search. Use `IOPMCopyAssertionsByProcess()` instead - it queries IOKit directly.

### Signal 2: "Microsoft Teams Audio" Virtual Device (SECONDARY - Event-Driven)

Teams creates a virtual audio device called "Microsoft Teams Audio" (CoreAudio device ID 121 on this machine). During a call, `kAudioDevicePropertyDeviceIsRunningSomewhere` transitions from `false` to `true`.

- **Event-driven** via `AudioObjectAddPropertyListenerBlock` - zero polling cost
- **No permissions required**
- The device exists whenever Teams is running; only the Running state changes during calls
- This should be the **first signal to fire** when a call starts

### Signal 3: Window Titles (CONFIRMED LIVE)

Teams uses pipe-separated window title format:
```
[Context] | [Details] | [Org] | [Email] | Microsoft Teams
```

**Idle/chat examples (confirmed on this machine):**
```
"Chat | NDX:Try Daily Stand-up | Integrated Corporate Services - Digital | chris.nesbitt-smith@digital.cabinet-office.gov.uk | Microsoft Teams"
"Andrews, Nick (DSIT) (External), +2 (External) | Cabinet Office | chris.nesbitt-smith@digital.cabinet-office.gov.uk | Microsoft Teams"
```

**Meeting window pattern (needs live meeting validation):**
First segment contains "Meeting", "Call with", or meeting subject title.

**Non-meeting windows to filter out:**
- `"Microsoft Teams"` (main idle window)
- `"Teams NRC"` (notification relay, 1x1 pixel hidden window at layer 20)
- First segment starting with "Chat", "Activity", "Calendar", "Files"

### Recommended Teams Detection Strategy
1. **Primary:** Monitor "Microsoft Teams Audio" virtual device running state (event-driven, instant, no permissions)
2. **Confirm:** Poll `IOPMCopyAssertionsByProcess()` every 3s for "Microsoft Teams Call in progress" (no permissions)
3. **Detail:** Read window title via CGWindowList to get meeting name (requires Screen Recording)

---

## Meeting Detection: Other Native Apps

### Zoom (`us.zoom.xos`, process: `zoom.us`)

| State | Window Title | Detection |
|-------|-------------|-----------|
| Idle | `"Zoom"` or `"Zoom Workplace"` | Ignore |
| **Active meeting** | `"Zoom Meeting"` | **DETECT** |
| **Webinar** | `"Zoom Webinar"` | **DETECT** |
| Waiting room | `"Zoom"` or `"Zoom - Waiting Room"` | Ignore |

**Detection:** `ownerName == "zoom.us" && (title == "Zoom Meeting" || title == "Zoom Webinar")`

**Note:** Zoom deliberately does NOT include meeting name/ID in window title. Zoom's virtual audio driver (`ZoomAudioDevice.driver`) loads into `coreaudiod` at boot and persists - NOT a meeting signal.

### Slack (`com.tinyspeck.slackmacgap`)

| State | Window Title | Detection |
|-------|-------------|-----------|
| Idle | `"[*] [Channel/DM] - [Workspace] - Slack"` | Ignore |
| **Huddle active** | Floating mini-player with `"huddle"` in title | **DETECT** |

**Detection:** `ownerName == "Slack" && title.lowercased().contains("huddle")`

**Notes:** Slack is Electron-based, creates many renderer windows (7+ observed). The huddle indicator is a **separate floating mini-player window**, NOT a title change on the main window. Live scan shows idle: `"* Pete Gale (DM) - GDS - Slack"`.

### FaceTime (`com.apple.FaceTime`)

| Signal | Reliability | Notes |
|--------|------------|-------|
| Window title | LOW | Stays "FaceTime" during calls - does NOT change |
| avconferenced daemon | **NOT RELIABLE** | Runs continuously for 12+ days for Handoff/Continuity Camera |
| Mic active + FaceTime running + on-screen window | MEDIUM | Best combo signal |
| `kAudioProcessPropertyIsRunningInput` on FaceTime PID | HIGH | macOS 14.2+ identifies which process uses mic |

**CRITICAL CORRECTION:** `avconferenced` is NOT a reliable FaceTime call indicator. It was running continuously for 12 days on this machine with no active FaceTime call. It persists for Handoff/Continuity Camera support.

**Recommended FaceTime detection:**
```
FaceTime is running (NSWorkspace)
  AND has on-screen window (CGWindowList)
  AND kAudioProcessPropertyIsRunningInput shows FaceTime PID using mic (CoreAudio)
```

### Amazon Chime (`com.amazon.Amazon-Chime`)

| State | Window Title |
|-------|-------------|
| Idle | `"Amazon Chime"` |
| **Active meeting** | `"Amazon Chime: [Name] Instant Meeting"` |
| **Meeting controls** | `"Amazon Chime: Meeting Controls"` (floating, layer 101) |
| **Screen share** | `"Amazon Chime: Screen Share Border"` (floating) |

**Detection:** `ownerName == "Amazon Chime" && title.matches(/^Amazon Chime: (Meeting Controls|Screen Share|.+Meeting)$/)`

**Note:** Not installed on this machine - all data from external research. Amazon Chime service ends February 20, 2026 - minimal investment recommended.

---

## CoreAudio & Process-Level Mic Monitoring

### Key Discovery: Per-Process Mic Identification (macOS 14.2+)

Starting with macOS 14.2 (Sonoma), Apple added **Process Object** APIs to CoreAudio that can identify WHICH process is using the microphone:

| Property | Selector | Purpose |
|----------|----------|---------|
| `kAudioHardwarePropertyProcessObjectList` | `'prs#'` | All audio client processes |
| `kAudioProcessPropertyIsRunningInput` | `'piri'` | Is process capturing audio input? |
| `kAudioProcessPropertyBundleID` | `'pbid'` | Bundle ID of the process |
| `kAudioProcessPropertyPID` | `'ppid'` | PID of the process |

Since our target is macOS 26 (Tahoe), these APIs are fully available.

### Swift Implementation: Get Processes Using Microphone

```swift
import CoreAudio

static func getProcessesUsingMicrophone() -> [(pid: pid_t, bundleID: String)] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
    ) == noErr else { return [] }

    let processCount = Int(size) / MemoryLayout<AudioObjectID>.size
    var processIDs = [AudioObjectID](repeating: 0, count: processCount)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processIDs
    ) == noErr else { return [] }

    var results: [(pid: pid_t, bundleID: String)] = []
    for processObjectID in processIDs {
        var isRunningInput: UInt32 = 0
        var runSize = UInt32(MemoryLayout<UInt32>.size)
        var runAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            processObjectID, &runAddress, 0, nil, &runSize, &isRunningInput
        ) == noErr, isRunningInput != 0 else { continue }

        // Get bundle ID
        var bundleIDRef: CFString = "" as CFString
        var bidSize = UInt32(MemoryLayout<CFString>.size)
        var bidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(processObjectID, &bidAddress, 0, nil, &bidSize, &bundleIDRef)

        // Get PID
        var pid: pid_t = 0
        var pidSize = UInt32(MemoryLayout<pid_t>.size)
        var pidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(processObjectID, &pidAddress, 0, nil, &pidSize, &pid)

        results.append((pid: pid, bundleID: bundleIDRef as String))
    }
    return results
}
```

### Mic Running State (Event-Driven, Zero-Cost)

```swift
// Listen for mic state changes on default input device
var address = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
AudioObjectAddPropertyListenerBlock(deviceID, &address, queue) { _, _ in
    let isInUse = Self.isMicrophoneInUse(deviceID: deviceID)
    // Trigger process enumeration to identify which app is using the mic
}
```

### Voice Activity Detection (macOS 14+)

- `kAudioDevicePropertyVoiceActivityDetectionEnable` (`'vAd+'`) - enable/disable
- `kAudioDevicePropertyVoiceActivityDetectionState` (`'vAdS'`) - 0=no voice, 1=voice detected
- Must enable first, then listen for state changes
- Only meaningful when input audio is active
- Supplementary signal: confirms someone is speaking (not just a muted meeting)

### Per-App Virtual Audio Devices

| App | Virtual Device | Running State Changes During Calls |
|-----|---------------|-----------------------------------|
| **Microsoft Teams** | "Microsoft Teams Audio" (ID 121) | YES - toggles with call state |
| **Zoom** | "ZoomAudioDevice" | Loads at boot, persists - NOT a call signal |

**Key insight:** Teams' virtual audio device running state is effectively a free, event-driven, no-permission-required meeting detection signal.

---

## CGWindowList Window Title Scanning

### API Performance (Benchmarked on This Machine)

| Option | Time per Call | Windows Returned |
|--------|-------------|-----------------|
| `.optionAll` | 6.94 ms | 440 |
| `.optionOnScreenOnly` | 1.04 ms | 63 |
| `.onScreenOnly + .excludeDesktopElements` | **0.93 ms** | 58 |

**Recommendation:** Poll every 2-3 seconds using `.optionOnScreenOnly` + `.excludeDesktopElements`. At 0.93ms per call, CPU overhead is ~0.03%.

### Permission Requirements

| Property | Without Screen Recording | With Screen Recording |
|----------|------------------------|---------------------|
| `kCGWindowOwnerName` | Available | Available |
| `kCGWindowOwnerPID` | Available | Available |
| `kCGWindowName` | **Empty string** | **Actual title** |
| `kCGWindowBounds` | Available | Available |
| `kCGWindowIsOnscreen` | Available | Available |

- `CGWindowListCopyWindowInfo` **never triggers a permission prompt** - it silently returns filtered data
- Use `CGPreflightScreenCaptureAccess()` to check permission, `CGRequestScreenCaptureAccess()` to prompt
- Even without Screen Recording, you can detect which apps are running and have visible windows

### Window Title Patterns Summary

| App | Process Name | Idle Title | Meeting Title | Regex |
|-----|-------------|-----------|--------------|-------|
| **Teams** | `Microsoft Teams` | `Chat \| ... \| Microsoft Teams` | `[Meeting] \| ... \| Microsoft Teams` | First segment keywords |
| **Zoom** | `zoom.us` | `Zoom Workplace` | `Zoom Meeting` / `Zoom Webinar` | `^Zoom (Meeting\|Webinar)$` |
| **Slack** | `Slack` | `[Channel] - [Workspace] - Slack` | Separate window with `huddle` | `(?i)huddle` |
| **FaceTime** | `FaceTime` | `FaceTime` | `FaceTime` (no change) | N/A - use mic signal |
| **Chime** | `Amazon Chime` | `Amazon Chime` | `Amazon Chime: Meeting Controls` | `^Amazon Chime: .+` |
| **Browser (Meet)** | `Comet`/`Chrome` | Tab title | `... - Google Meet - Comet` | `(?i)google meet` |

### Hybrid Detection Architecture

```
NSWorkspace notifications (free) → Know which meeting apps are running
  ↓
CGWindowList poll every 3s (0.93ms) → Only when relevant apps are running
  ↓
Pattern matching → Match titles to meeting patterns
  ↓
State machine → Debounce: 2 consecutive detections to start, 3 misses to end
  ↓
MacWhisper AX automation → Press "Record [App]" / "Stop Recording"
```

---

## Host Application Architecture

**App type:** macOS menu bar app (no dock icon, `LSUIElement = true`)
**Framework:** AppKit foundation + SwiftUI views (hybrid)
**Min target:** macOS 26 (Tahoe)
**Distribution:** Developer ID + notarization + DMG (outside App Store)

**Why hybrid AppKit + SwiftUI:**
- `NSStatusBar`/`NSStatusItem` for menu bar (AppKit gives full control)
- SwiftUI for popover/settings UI via `NSHostingView`
- Pure SwiftUI `MenuBarExtra` is too limited for dynamic icon updates

**WebSocket server: Network.framework (`NWListener` + `NWProtocolWebSocket`)**
- Zero external dependencies
- Browser extension connects to `ws://127.0.0.1:8765`
- **WebSocket chosen over Chrome Native Messaging** because:
  - MV3 kills Native Messaging host after ~5 minutes (service worker suspension)
  - Content scripts can't connect directly via Native Messaging
  - Single server works for all Chromium browsers

**Required permissions:**

| Permission | Why Needed |
|-----------|-----------|
| Screen Recording | Read window titles via `kCGWindowName` |
| Accessibility | AXObserver for window events, MacWhisper UI automation |

**Entitlements (non-sandboxed):**
```xml
<key>com.apple.security.app-sandbox</key>
<false/>
<key>com.apple.security.automation.apple-events</key>
<true/>
<key>com.apple.security.network.server</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

**Project structure:**
```
MacWhisperAuto/
├── Sources/
│   ├── App/           (AppDelegate, StatusMenuView, Info.plist)
│   ├── Core/          (AppState, MeetingDetector, AppMonitor, DebounceTimer)
│   ├── Networking/    (WebSocketServer, MessageProtocol)
│   ├── Automation/    (MacWhisperController, AccessibilityHelper)
│   └── Detection/     (PlatformDetector protocol, per-app detectors)
├── Entitlements/
└── Extension/         (Chromium browser extension - MV3)
```

---

## Browser Extension Architecture

**Full documentation:** [`browser-extension-meeting-detection-research-2026-02-06.md`](./browser-extension-meeting-detection-research-2026-02-06.md)

### Key Findings Summary

- **WebSocket from service worker: YES** (Chrome 116+, with 20-second keepalive heartbeat)
- **WebSocket from content script: NO** (blocked by host page CSP `connect-src` directive)
- **Content scripts in background tabs: YES** (continue running, not suspended)
- **MV3 service worker lifecycle:** Suspends after 30s of no events; heartbeat prevents this

### Two-Tier Detection Strategy

**Tier 1 (cheap, service worker):** Monitor tab URLs + titles via `chrome.tabs` API
**Tier 2 (deep, on demand):** Inject detection function via `chrome.scripting.executeScript` that scans `document.body.textContent` for meeting-state keywords ("Leave call", "Hang up", "End Meeting")

### WebSocket Message Protocol

Heartbeat (every 20s) doubles as keepalive and state sync:
```json
{
  "type": "heartbeat",
  "active_meetings": [{"platform": "google-meet", "tab_id": 123, "title": "..."}],
  "timestamp": 1707235220000
}
```

Host app can reconstruct full state from any single heartbeat (stateless polling principle).

### Per-Platform URL Patterns

| Platform | URL Pattern | Content Script Match |
|----------|-----------|---------------------|
| Google Meet | `meet.google.com/*` | `*://meet.google.com/*` |
| Teams Web | `teams.microsoft.com/*`, `teams.live.com/*` | `*://teams.microsoft.com/*` |
| Zoom Web | `app.zoom.us/wc/*`, `zoom.us/wc/*` | `*://app.zoom.us/*` |
| Slack Web | `app.slack.com/*` | `*://app.slack.com/*` |
| Chime Web | `app.chime.aws/*` | `*://app.chime.aws/*` |

---

## Recommended Detection Strategy

### Architecture: Layered Signal Fusion

```
Layer 0: NSWorkspace notifications (free, event-driven)
  → Track which meeting apps are running
  → Gate all subsequent layers (don't poll if no meeting apps running)

Layer 1: CoreAudio event-driven signals (free, instant, no permissions)
  → "Microsoft Teams Audio" device running state
  → kAudioDevicePropertyDeviceIsRunningSomewhere on default input
  → kAudioProcessPropertyIsRunningInput for per-process mic identification

Layer 2: IOPMAssertion polling (free, no permissions, 3s interval)
  → "Microsoft Teams Call in progress"
  → Other apps may also create power assertions during calls

Layer 3: CGWindowList polling (0.93ms, Screen Recording required, 3s interval)
  → Pattern match window titles for all platforms
  → Only poll when Layer 0 indicates relevant apps are running

Layer 4: Browser extension WebSocket (event-driven)
  → Meeting detection for Google Meet, Teams web, Zoom web, Slack web, Chime web
  → Two-tier: URL/title match → DOM content keyword scan

Layer 5: AXObserver (event-driven, Accessibility required)
  → Window creation/destruction/title change notifications
  → MacWhisper recording state monitoring
```

### Per-Platform Recommended Signals

| Platform | Primary Signal | Secondary Signal | Permission |
|----------|---------------|-----------------|-----------|
| **Teams native** | Teams Audio virtual device running | IOPMAssertion "Microsoft Teams Call in progress" | None |
| **Zoom native** | CGWindowList `"Zoom Meeting"` | Mic activity on zoom.us PID | Screen Recording |
| **Slack native** | CGWindowList window with `"huddle"` | Mic activity on Slack PID | Screen Recording |
| **FaceTime** | CoreAudio process-level mic on FaceTime PID | FaceTime running + on-screen window | None |
| **Chime native** | CGWindowList `"Amazon Chime: Meeting Controls"` | Mic activity | Screen Recording |
| **Browser meetings** | Extension WebSocket events | CGWindowList browser title matching | Extension + Screen Recording |

### Debounce Strategy

- **Meeting start:** Require 2 consecutive detections (6 seconds) before triggering recording
- **Meeting end:** Require 3 consecutive misses (9 seconds) before stopping recording
- **Configurable grace period** for end detection (default 10 seconds)
- **Fail long over fail short:** Better to record extra than miss audio

---

## Accessibility API Reference

**Framework:** `ApplicationServices` (C-based, bridged to Swift)

| Function | Purpose |
|----------|---------|
| `AXUIElementCreateApplication(pid)` | Get element for an app by PID |
| `AXUIElementCopyAttributeValue(element, attribute, &value)` | Read attribute |
| `AXUIElementPerformAction(element, action)` | Click/press |
| `AXIsProcessTrustedWithOptions(options)` | Check/prompt for permission |
| `AXObserverCreate` + `AXObserverAddNotification` | Subscribe to UI events |
| `AXUIElementSetMessagingTimeout(element, seconds)` | Prevent hangs |

---

## Items Requiring Live Meeting Validation

| Item | Platform | How to Validate |
|------|----------|----------------|
| Teams window title during active call | Teams native | Join meeting, capture CGWindowList |
| Teams IOPMAssertion creation timing | Teams native | Join meeting, poll IOPMCopyAssertionsByProcess |
| Teams Audio device running state toggle | Teams native | Join meeting, monitor AudioObject |
| Zoom window title exact format | Zoom native | Join meeting, capture CGWindowList |
| Slack huddle mini-player window title | Slack native | Start huddle, capture CGWindowList |
| FaceTime window title during call | FaceTime | Make call, check CGWindowList |
| FaceTime CoreAudio process-level mic | FaceTime | Make call, check kAudioProcessPropertyIsRunningInput |
| Google Meet DOM selectors | Browser | Join meeting, inspect DevTools |
| WebSocket in Comet browser | Extension | Test service worker WebSocket |
| textContent keyword localization | All platforms | Test with English locale |

---

## Prior Art & References

- **alt-tab-macos** (https://github.com/lwouis/alt-tab-macos) - CGWindowList + AXObserver combined window tracking
- **TeamsStatusMacOS** (https://github.com/RobertD502/TeamsStatusMacOS) - Teams detection via powerd logs (**BROKEN on macOS 26**)
- **teams-call** (https://github.com/mre/teams-call) - Teams call detection shell script
- Apple Developer Documentation: [CGWindowListCopyWindowInfo](https://developer.apple.com/documentation/coregraphics/1455137-cgwindowlistcopywindowinfo)
- Apple Developer Documentation: [AXUIElement](https://developer.apple.com/documentation/applicationservices/axuielement_h)
- Apple WWDC23 Session 10235: [What's new in voice processing](https://developer.apple.com/videos/play/wwdc2023/10235/) (CoreAudio VAD)
- Chrome Extensions: [Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)

---

## POC Files

| File | Purpose |
|------|---------|
| `poc/dump-ax-tree.swift` | Dumps MacWhisper's full accessibility tree |
| `poc/trigger-record.swift` | Triggers MacWhisper recording for specific app |
| `poc/stop-record.swift` | Stops MacWhisper recording via status bar menu |
| `poc/explore-app-audio.swift` | Deep AX exploration of MacWhisper's App Audio screen |
