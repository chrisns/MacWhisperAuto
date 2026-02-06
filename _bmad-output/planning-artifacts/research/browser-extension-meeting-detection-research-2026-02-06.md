# Browser Extension Architecture for Meeting Detection

**Date:** 2026-02-06
**Scope:** Chromium MV3 extension for Chrome, Comet, Arc, Edge, Brave
**Target Platforms:** Google Meet, Microsoft Teams web, Zoom web, Slack web, Amazon Chime web
**Communication:** WebSocket to host macOS app at `ws://127.0.0.1:8765`

---

## Table of Contents

1. [MV3 Extension Architecture for Meeting Detection](#1-mv3-extension-architecture-for-meeting-detection)
2. [WebSocket Client from Extension](#2-websocket-client-from-extension)
3. [Per-Platform DOM Detection Signals](#3-per-platform-dom-detection-signals)
4. [Two-Tier Detection Strategy Implementation](#4-two-tier-detection-strategy-implementation)
5. [Robustness Considerations](#5-robustness-considerations)
6. [WebSocket Message Protocol Design](#6-websocket-message-protocol-design)

---

## 1. MV3 Extension Architecture for Meeting Detection

### Service Worker vs Content Scripts: Division of Responsibilities

**Service Worker (background.js):**
- Runs as the extension's background process, event-driven
- Has access to all `chrome.*` extension APIs (`chrome.tabs`, `chrome.scripting`, `chrome.alarms`, `chrome.storage`)
- Can query and monitor ALL tabs across ALL windows simultaneously
- Coordinates content scripts, manages state, handles WebSocket connection
- Cannot access page DOM directly
- Suspends after ~30 seconds of inactivity (but kept alive by WebSocket keepalive messages since Chrome 116)

**Content Scripts:**
- Injected into specific web pages matching URL patterns
- Have full DOM access to the page they are injected into
- Run in an "isolated world" -- same DOM, separate JavaScript context
- Can communicate with service worker via `chrome.runtime.sendMessage()` / `chrome.runtime.connect()`
- Cannot access `chrome.tabs` or most `chrome.*` APIs
- Continue running in background tabs (not affected by tab focus)
- Subject to the host page's Content Security Policy for network requests

**Optimal Architecture:**
```
Service Worker (background.js)
  ├── WebSocket client to ws://127.0.0.1:8765 (keepalive every 20s)
  ├── chrome.tabs.onUpdated listener (Tier 1: URL/title monitoring)
  ├── chrome.alarms periodic poll (every 30-60s backup)
  ├── chrome.scripting.executeScript for on-demand DOM inspection
  ├── State management via chrome.storage.local
  └── Message relay between content scripts and WebSocket

Content Scripts (per meeting platform)
  ├── Injected into meeting platform pages via manifest match patterns
  ├── MutationObserver for DOM changes (meeting controls appearing/disappearing)
  ├── Periodic DOM polling for meeting state keywords
  └── Report state changes to service worker via chrome.runtime.sendMessage
```

### How Content Scripts Inspect ALL Tabs (Not Just Active)

Content scripts do NOT inspect all tabs. Instead, the architecture uses two complementary approaches:

**Approach A: Service worker queries all tabs via `chrome.tabs` API**
```javascript
// Service worker can query ALL open tabs at any time
const tabs = await chrome.tabs.query({});
for (const tab of tabs) {
  // Check URL and title of every tab
  if (isMeetingUrl(tab.url)) {
    // Tier 1 match -- request deeper inspection
  }
}
```

**Approach B: Content scripts auto-inject into matching URLs via manifest**
```json
{
  "content_scripts": [
    {
      "matches": [
        "*://meet.google.com/*",
        "*://teams.microsoft.com/*",
        "*://teams.live.com/*",
        "*://app.zoom.us/*",
        "*://zoom.us/wc/*",
        "*://app.slack.com/*",
        "*://app.chime.aws/*"
      ],
      "js": ["content-script.js"],
      "run_at": "document_idle"
    }
  ]
}
```

Content scripts injected via manifest `content_scripts` run in ALL matching tabs, including background tabs. This is the key advantage over Tampermonkey -- the content script runs regardless of whether the tab is active/focused.

**Approach C: On-demand injection via `chrome.scripting.executeScript`**
```javascript
// Service worker can inject a function into any specific tab
const results = await chrome.scripting.executeScript({
  target: { tabId: tabId },
  func: () => {
    // This runs in the tab's context
    const bodyText = document.body.textContent;
    return {
      hasLeaveButton: bodyText.includes('Leave') || bodyText.includes('Leave call'),
      hasMuteButton: bodyText.includes('Mute') || bodyText.includes('Unmute'),
      title: document.title
    };
  }
});
const domState = results[0].result;
```

**Key constraint:** The injected function is serialized and cannot reference outer scope variables (no closures).

### chrome.tabs API for Tab Title Monitoring

```javascript
// Listen for URL and title changes on ALL tabs
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  // changeInfo contains ONLY the properties that changed
  // changeInfo.url     -- set when URL changes
  // changeInfo.title   -- set when page title changes
  // changeInfo.status  -- 'loading' or 'complete'
  // changeInfo.audible -- set when audio state changes

  if (changeInfo.url || changeInfo.title) {
    checkForMeetingSignals(tabId, tab.url, tab.title, tab.audible);
  }
});

// Listen for tab removal (meeting tab closed)
chrome.tabs.onRemoved.addListener((tabId, removeInfo) => {
  if (activeMeetings.has(tabId)) {
    handleMeetingEnded(tabId);
  }
});

// On-demand: query all tabs matching meeting URL patterns
async function scanAllTabs() {
  const tabs = await chrome.tabs.query({
    url: [
      '*://meet.google.com/*',
      '*://teams.microsoft.com/*',
      '*://teams.live.com/*',
      '*://app.zoom.us/*',
      '*://zoom.us/wc/*',
      '*://app.slack.com/*',
      '*://app.chime.aws/*'
    ]
  });
  return tabs;
}
```

### chrome.scripting.executeScript for On-Demand DOM Inspection

```javascript
// Execute a function in a specific tab's page context
async function inspectTabDOM(tabId) {
  try {
    const results = await chrome.scripting.executeScript({
      target: { tabId: tabId },
      func: detectMeetingState  // must be a standalone function
    });
    return results[0]?.result;
  } catch (err) {
    // Tab may have navigated away, been closed, or URL is restricted
    console.warn(`Cannot inspect tab ${tabId}:`, err.message);
    return null;
  }
}

// This function runs in the page context -- no access to extension APIs
function detectMeetingState() {
  const bodyText = document.body?.textContent || '';
  const title = document.title;

  // Keywords that indicate an active meeting
  const activeKeywords = ['Leave call', 'Leave meeting', 'Leave', 'End call',
                          'Mute', 'Unmute', 'Share screen', 'Stop sharing',
                          'participants', 'Recording'];

  const matchedKeywords = activeKeywords.filter(kw => bodyText.includes(kw));

  // Check for meeting-specific iframes
  const iframes = Array.from(document.querySelectorAll('iframe'));
  const meetingIframes = iframes.filter(iframe => {
    const src = iframe.src || '';
    return src.includes('meet.google.com') ||
           src.includes('teams.microsoft.com') ||
           src.includes('zoom.us');
  });

  return {
    title: title,
    url: location.href,
    matchedKeywords: matchedKeywords,
    keywordCount: matchedKeywords.length,
    iframeCount: meetingIframes.length,
    isLikelyInMeeting: matchedKeywords.length >= 2
  };
}
```

### Tab Audible/Muted State

```javascript
// tab.audible (boolean): true when tab is producing sound
// Useful as a SUPPLEMENTARY signal -- meeting with active audio
// WARNING: Not primary signal. Muted participants, silence = false

// tab.mutedInfo (object):
//   .muted (boolean): whether tab audio is muted
//   .reason (string): 'user' | 'capture' | 'extension'

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.audible !== undefined) {
    // Audio state changed for this tab
    if (tab.audible && isMeetingTab(tabId)) {
      // Meeting tab is producing audio -- strong confirmation signal
    }
  }
});
```

**Important:** `tab.audible` is unreliable as a primary meeting indicator because:
- Muted microphone = no outgoing audio but meeting is still active
- Webinar/listen-only mode = may have periods of silence
- Audio might come from meeting notifications, not the actual call
- Use as a supplementary confirmation signal only (per brainstorming findings)

### Permission Requirements

**manifest.json:**
```json
{
  "manifest_version": 3,
  "name": "MacWhisperAuto Meeting Detector",
  "version": "1.0.0",
  "minimum_chrome_version": "116",

  "permissions": [
    "tabs",
    "scripting",
    "alarms",
    "storage"
  ],

  "host_permissions": [
    "*://meet.google.com/*",
    "*://teams.microsoft.com/*",
    "*://teams.live.com/*",
    "*://app.zoom.us/*",
    "*://zoom.us/wc/*",
    "*://app.slack.com/*",
    "*://app.chime.aws/*"
  ],

  "background": {
    "service_worker": "background.js"
  },

  "content_scripts": [
    {
      "matches": [
        "*://meet.google.com/*",
        "*://teams.microsoft.com/*",
        "*://teams.live.com/*",
        "*://app.zoom.us/*",
        "*://zoom.us/wc/*",
        "*://app.slack.com/*",
        "*://app.chime.aws/*"
      ],
      "js": ["content-script.js"],
      "run_at": "document_idle"
    }
  ]
}
```

**Permission details:**

| Permission | Why Needed |
|-----------|-----------|
| `tabs` | Read `tab.url`, `tab.title`, `tab.audible` for ALL tabs. Without this, URL/title only visible for activeTab on user gesture. |
| `scripting` | Required for `chrome.scripting.executeScript()` on-demand DOM inspection. |
| `alarms` | `chrome.alarms.create()` for periodic polling backup (wakes service worker). |
| `storage` | `chrome.storage.local` for persisting state across service worker suspensions. |
| `host_permissions` | Required alongside `scripting` to actually inject scripts. Also enables reading full URL (not just origin) for matching tabs. |

**NOT needed:**
- `activeTab` -- we need ALL tabs, not just the active one on user gesture
- `notifications` -- we notify the host app, not the user directly
- `nativeMessaging` -- using WebSocket instead
- `offscreen` -- not needed since WebSocket works in service worker (Chrome 116+)

---

## 2. WebSocket Client from Extension

### Can a Service Worker Connect to ws://127.0.0.1:8765?

**YES, since Chrome 116.** WebSocket connections in MV3 service workers are officially supported with a keepalive requirement.

**Source:** https://developer.chrome.com/docs/extensions/how-to/web-platform/websockets

**Key rules:**
1. The service worker remains active as long as WebSocket messages are exchanged within every 30-second window
2. You must send a keepalive message every 20 seconds (buffer before the 30s deadline)
3. The manifest must specify `"minimum_chrome_version": "116"`
4. Either client or server messages count -- any traffic resets the 30s timer

**This is the recommended approach.** It is simpler than all alternatives:
- No Native Messaging host manifest installation per browser
- No offscreen document (WebSocket is not a supported offscreen reason anyway)
- No content script CSP issues (content scripts inherit page CSP, which blocks localhost WebSocket)
- No hidden popup window hack

### WebSocket Connection Implementation

```javascript
// background.js (service worker)

let ws = null;
let reconnectAttempts = 0;
const MAX_RECONNECT_DELAY = 30000; // 30 seconds max
const KEEPALIVE_INTERVAL = 20000;  // 20 seconds
let keepaliveTimer = null;

function connectWebSocket() {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
    return;
  }

  try {
    ws = new WebSocket('ws://127.0.0.1:8765');
  } catch (err) {
    console.error('WebSocket construction failed:', err);
    scheduleReconnect();
    return;
  }

  ws.onopen = () => {
    console.log('WebSocket connected to host app');
    reconnectAttempts = 0;
    startKeepalive();

    // Send current state immediately on connect
    sendCurrentMeetingState();
  };

  ws.onmessage = (event) => {
    try {
      const msg = JSON.parse(event.data);
      handleHostMessage(msg);
    } catch (err) {
      console.warn('Invalid message from host:', event.data);
    }
  };

  ws.onclose = (event) => {
    console.log(`WebSocket closed: code=${event.code} reason=${event.reason}`);
    stopKeepalive();
    ws = null;
    scheduleReconnect();
  };

  ws.onerror = (event) => {
    console.error('WebSocket error');
    // onclose will fire after onerror
  };
}

function startKeepalive() {
  stopKeepalive();
  keepaliveTimer = setInterval(() => {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({
        type: 'heartbeat',
        active_meetings: getActiveMeetingsSummary(),
        timestamp: Date.now()
      }));
    } else {
      stopKeepalive();
    }
  }, KEEPALIVE_INTERVAL);
}

function stopKeepalive() {
  if (keepaliveTimer) {
    clearInterval(keepaliveTimer);
    keepaliveTimer = null;
  }
}

function scheduleReconnect() {
  // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s, 30s, ...
  const delay = Math.min(1000 * Math.pow(2, reconnectAttempts), MAX_RECONNECT_DELAY);
  reconnectAttempts++;
  console.log(`Reconnecting in ${delay}ms (attempt ${reconnectAttempts})`);
  setTimeout(connectWebSocket, delay);
}

function sendMessage(msg) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(msg));
  } else {
    // Queue message or log warning
    console.warn('WebSocket not connected, message dropped:', msg.type);
  }
}
```

### WebSocket Reconnection Strategy When Service Worker Wakes

```javascript
// Event listeners MUST be registered synchronously at top level
// They persist across service worker wake cycles

chrome.runtime.onInstalled.addListener(() => {
  connectWebSocket();
});

chrome.runtime.onStartup.addListener(() => {
  connectWebSocket();
});

// Alarm ensures reconnection even if service worker was suspended
chrome.alarms.create('reconnect-check', { periodInMinutes: 0.5 }); // every 30 seconds

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'reconnect-check') {
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      connectWebSocket();
    }
  }
  if (alarm.name === 'meeting-poll') {
    scanAllTabsForMeetings();
  }
});

// Also reconnect when any tab event occurs (service worker was woken for this event)
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  // Ensure WebSocket is connected whenever service worker is active
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    connectWebSocket();
  }
  // ... handle tab update ...
});
```

### Content Script Direct WebSocket: Why NOT

Content scripts inherit the host page's Content Security Policy (CSP) for network requests. This means:

- A content script on `meet.google.com` is subject to Google Meet's `connect-src` CSP directive
- Google Meet's CSP almost certainly does NOT allow `ws://127.0.0.1:8765`
- The WebSocket connection from the content script will be **silently blocked**
- Using `"world": "MAIN"` injection does NOT bypass CSP -- it makes CSP restrictions MORE applicable

**Therefore:** All WebSocket communication goes through the service worker. Content scripts communicate with the service worker via `chrome.runtime.sendMessage()`, which is an extension-internal channel not subject to page CSP.

```
Content Script --> chrome.runtime.sendMessage() --> Service Worker --> WebSocket --> Host App
Host App --> WebSocket --> Service Worker --> chrome.tabs.sendMessage() --> Content Script
```

### Alternative: HTTP Polling (Fallback)

If WebSocket proves problematic in practice (e.g., on Comet browser), `fetch()` to a localhost HTTP endpoint is a viable fallback:

```javascript
// Service worker can use fetch() to POST to localhost
async function sendViaHttp(message) {
  try {
    const response = await fetch('http://127.0.0.1:8765/api/event', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(message)
    });
    return await response.json();
  } catch (err) {
    console.warn('HTTP POST failed:', err);
  }
}
```

**Tradeoffs vs WebSocket:**
- Higher latency per event (HTTP request/response overhead)
- Server-to-extension communication requires polling (no push)
- Simpler implementation, fewer lifecycle concerns
- Works even if service worker suspends between polls (each fetch is independent)

---

## 3. Per-Platform DOM Detection Signals

### IMPORTANT NOTE

All CSS selectors and DOM structures below are based on research as of February 2026. Meeting platforms update their UI frequently. These selectors MUST be validated via live inspection (browser DevTools) before implementation, and a maintenance process must be planned for when they break.

The **textContent keyword scanning** approach (from brainstorming findings) is more resilient than CSS selectors because text labels change less frequently than DOM class names and structure.

---

### 3.1 Google Meet

**URL Patterns:**
```
*://meet.google.com/*
```
Specific patterns:
- Lobby/join: `meet.google.com/xxx-xxxx-xxx` (meeting code format: 3-4-3 lowercase letters)
- Active meeting: same URL, but DOM state changes

**Tab Title Patterns:**

| State | Title Format | Notes |
|-------|-------------|-------|
| Lobby (pre-join) | `"Meet - xxx-xxxx-xxx - Google Chrome"` or `"Ready to join - Google Meet"` | Meeting code visible |
| Active meeting | `"Meeting Title - Google Meet"` | Title may show meeting name from calendar |
| With participants panel | `"participants (N) - Meeting Title"` | N = participant count; only when People panel is open |
| Meeting ended | `"You left the meeting - Google Meet"` or `"Meeting ended - Google Meet"` | Clear signal |
| Just Google Meet tab | `"Google Meet"` | Home page, no meeting |

**Regex for title matching:**
```javascript
const GMEET_TITLE_PATTERNS = {
  active: /^(?!.*(?:left the meeting|ended)).*-\s*Google Meet$/,
  ended: /(?:left the meeting|Meeting ended|ended)/i,
  lobby: /(?:Ready to join|Getting ready)/i,
  participants: /^participants\s*\(\d+\)/i
};
```

**DOM Signals (require live validation):**

| Signal | Selector / Detection | Confidence | Stability |
|--------|---------------------|------------|-----------|
| Leave call button | `button[aria-label="Leave call"]` | HIGH | Medium -- aria-label text may change |
| Leave call button (text) | `document.body.textContent.includes('Leave call')` | HIGH | High -- text label stable |
| Meeting code attribute | `[data-meeting-code]` | MEDIUM | Needs validation |
| Participant count | Sidebar element containing "N participants" | MEDIUM | Low -- structural changes |
| Meeting timer | Header clock element, `[role="timer"]` | MEDIUM | Low -- class names change |
| Microphone toggle | `button[aria-label*="microphone"]` or `button[aria-label*="Mute"]` | HIGH | Medium |
| Camera toggle | `button[aria-label*="camera"]` | HIGH | Medium |
| End call button (red) | `button[aria-label="Leave call"]` with red styling | HIGH | Medium |
| Captions/CC button | `button[aria-label*="captions"]` | MEDIUM | Medium |

**Recommended textContent keywords for Google Meet:**
```javascript
const GMEET_ACTIVE_KEYWORDS = [
  'Leave call',      // Primary active meeting indicator
  'Mute',            // Mic control present
  'Turn off camera', // Camera control present
  'Present now',     // Screen share option
  'Captions',        // CC available
  'More options',    // Meeting controls expanded
];

const GMEET_ENDED_KEYWORDS = [
  'You left the meeting',
  'Meeting ended',
  'Return to home screen',
  'Rejoin',
];
```

**iframe detection:** Google Meet does NOT typically embed its call in a sub-iframe on `meet.google.com` itself. The meeting UI renders directly in the main document. However, if Meet is embedded in another page (e.g., Google Calendar sidebar), it uses an iframe with `src` containing `meet.google.com`.

---

### 3.2 Microsoft Teams Web

**URL Patterns:**
```
*://teams.microsoft.com/*
*://teams.live.com/*
```

Note: Microsoft has been migrating Teams web to new URLs. Also check:
```
*://teams.cloud.microsoft/*
```

**Tab Title Patterns:**

| State | Title Format | Notes |
|-------|-------------|-------|
| Normal Teams | `"Microsoft Teams"` | Chat/channels view |
| In meeting | `"Meeting with [Name]"` or `"[Meeting Title] \| Microsoft Teams"` | Title updates dynamically |
| Call | `"Call with [Name] \| Microsoft Teams"` | 1:1 or group call |
| Teams lobby | `"[Meeting Title] \| Microsoft Teams"` | Same as in-meeting; need DOM check |

**Regex for title matching:**
```javascript
const TEAMS_TITLE_PATTERNS = {
  meeting: /(?:Meeting with|Call with)/i,
  general: /Microsoft Teams/i,
  meetingTitle: /^.+\s*\|\s*Microsoft Teams$/  // "Title | Microsoft Teams"
};
```

**DOM Signals (require live validation):**

| Signal | Selector / Detection | Confidence | Notes |
|--------|---------------------|------------|-------|
| Leave button | `button[aria-label*="Leave"]` | HIGH | Multiple Leave variants |
| Leave button | `[data-tid="leave-call-button"]` | HIGH | Teams-specific data attribute |
| Call controls bar | `[data-tid="call-controls"]` | HIGH | Container for all call controls |
| Call controls bar (alt) | `.ts-call-control-bar` | MEDIUM | Class name may change |
| Mute button | `button[aria-label*="Mute"]` | HIGH | Present during active call |
| Camera button | `button[aria-label*="Camera"]` or `button[aria-label*="Video"]` | HIGH | Present during call |
| Share button | `button[aria-label*="Share"]` | MEDIUM | Screen share control |
| Meeting stage | `[data-tid="meeting-stage"]` | MEDIUM | Meeting video area |
| Hang up button | `button[aria-label*="Hang up"]` or `button[aria-label*="hang up"]` | HIGH | Red end call button |

**Important caveats:**
- Teams uses React/Angular components with Shadow DOM in newer builds (2025 Wave 1)
- Shadow DOM elements require `element.shadowRoot.querySelector()` to traverse
- Teams heavily uses `data-tid` attributes which are more stable than class names
- Teams web app may load meeting UI in nested iframes/webviews

**Recommended textContent keywords for Teams:**
```javascript
const TEAMS_ACTIVE_KEYWORDS = [
  'Leave',           // Leave button text
  'Hang up',         // End call
  'Mute',            // Audio control
  'Unmute',          // Audio control (alternative state)
  'Share',           // Screen share
  'More actions',    // Call controls menu
  'Raise',           // Raise hand feature
];

const TEAMS_ENDED_KEYWORDS = [
  'Call ended',
  'You left the meeting',
  'Rejoin',
  'Meeting has ended',
];
```

**Shadow DOM handling strategy:**
```javascript
function deepQuerySelector(root, selector) {
  // Try direct query first
  let result = root.querySelector(selector);
  if (result) return result;

  // Walk shadow roots
  const allElements = root.querySelectorAll('*');
  for (const el of allElements) {
    if (el.shadowRoot) {
      result = el.shadowRoot.querySelector(selector);
      if (result) return result;
    }
  }
  return null;
}
```

---

### 3.3 Zoom Web Client

**URL Patterns:**
```
*://app.zoom.us/wc/*
*://zoom.us/wc/*
*://zoom.us/j/*
```

Note: Zoom web client uses different URL structures:
- `app.zoom.us/wc/<meeting-id>/join` -- joining a meeting
- `zoom.us/wc/<meeting-id>/start` -- starting a meeting
- `zoom.us/j/<meeting-id>` -- join redirect (may redirect to native app)

**Tab Title Patterns:**

| State | Title Format | Notes |
|-------|-------------|-------|
| Join page | `"Join Meeting - Zoom"` or `"Launch Meeting - Zoom"` | Pre-join |
| Active meeting | `"Zoom Meeting"` | Generic; some meetings show custom title |
| Active meeting (named) | `"[Meeting Title] - Zoom Meeting"` | If organizer set a topic |
| Webinar | `"Zoom Webinar"` | Different from meeting |
| Post-meeting | `"Meeting Ended"` | Clear signal |

**Regex for title matching:**
```javascript
const ZOOM_TITLE_PATTERNS = {
  active: /Zoom (?:Meeting|Webinar)/i,
  joining: /(?:Join|Launch) Meeting.*Zoom/i,
  ended: /Meeting Ended/i
};
```

**DOM Signals (require live validation):**

| Signal | Selector / Detection | Confidence | Notes |
|--------|---------------------|------------|-------|
| Leave button | `button[aria-label="Leave"]` or `button.leave-meeting-btn` | HIGH | Needs validation |
| Leave button (text) | Text content containing "Leave" in meeting toolbar | HIGH | More resilient |
| Meeting controls footer | `.meeting-client` or `.footer-button-base__button` | MEDIUM | Zoom uses custom class names |
| Mute button | `button[aria-label*="mute"]` (case-insensitive) | HIGH | Standard meeting control |
| Video button | `button[aria-label*="video"]` or `button[aria-label*="camera"]` | HIGH | Standard control |
| Share screen button | `button[aria-label*="share"]` or `button[aria-label*="Share Screen"]` | MEDIUM | May vary |
| Participant panel | `.participants-section__participants-list` | LOW | Class names change frequently |
| Waiting room | Text "Please wait, the meeting host will let you in soon" | HIGH | Text-based, stable |
| Meeting info | `.meeting-info-container` | LOW | Class names change |

**Important caveats:**
- Zoom web client has NO public DOM documentation
- CSS class names in Zoom are frequently obfuscated/minified (e.g., hashed class names)
- Zoom strongly prefers users install native app -- web client may show "Download" prompts
- aria-label attributes are more stable than class names for Zoom
- Zoom's web SDK documentation covers developer-embedded views, NOT the app.zoom.us DOM

**Recommended textContent keywords for Zoom:**
```javascript
const ZOOM_ACTIVE_KEYWORDS = [
  'Leave',             // Leave button
  'End Meeting',       // Host end option
  'Mute',              // Audio control
  'Unmute',            // Audio control alternative
  'Start Video',       // Camera control
  'Stop Video',        // Camera control alternative
  'Share Screen',      // Screen share
  'Participants',      // Participant list button
  'Chat',              // In-meeting chat
];

const ZOOM_ENDED_KEYWORDS = [
  'Meeting Ended',
  'The host has ended the meeting',
  'You have been removed',
  'Leave Meeting',     // Confirmation dialog
];
```

---

### 3.4 Slack Web (Huddles)

**URL Patterns:**
```
*://app.slack.com/*
```

Note: Slack does NOT use separate URLs for huddles. The huddle UI overlays the existing Slack workspace page. The URL stays the same (e.g., `app.slack.com/client/T123/C456`).

**Tab Title Patterns:**

| State | Title Format | Notes |
|-------|-------------|-------|
| Normal Slack | `"[Channel] - [Workspace] \| Slack"` | Standard format |
| During huddle | May append huddle indicator or show `"Huddle"` | NEEDS LIVE VALIDATION |
| Notification | `"(N) [Channel] - [Workspace] \| Slack"` | Unread count prefix |

**Important:** Slack huddle tab title changes are UNRELIABLE as a primary signal. The huddle may or may not change the tab title depending on the Slack version. DOM inspection is essential for Slack.

**DOM Signals (require live validation):**

| Signal | Selector / Detection | Confidence | Notes |
|--------|---------------------|------------|-------|
| Huddle button | `[data-qa="huddle_icon"]` or `button[aria-label="Start a huddle"]` | MEDIUM | Location may change |
| Active huddle container | `.p-huddle_window` | MEDIUM | Class prefix `.p-` is Slack convention |
| Huddle active indicator | `div[aria-label="Huddle in progress"]` | MEDIUM | Needs validation |
| Huddle controls | `.c-huddle_controls` | MEDIUM | Camera/share buttons |
| Huddle thread toggle | `button[data-qa="huddle_thread_toggle"]` | MEDIUM | Thread side panel |
| Active indicator | `.client-channels__huddle-indicator` | MEDIUM | Presence indicator |
| Headphones icon (active) | Icon element when huddle is active | LOW | CSS class changes |
| Leave huddle button | `button[aria-label*="Leave huddle"]` or `button[aria-label*="Leave"]` | HIGH | Clear indicator |

**Recommended textContent keywords for Slack:**
```javascript
const SLACK_ACTIVE_KEYWORDS = [
  'Leave',              // Leave huddle button text
  'Huddle',             // Huddle UI label
  'Mute',               // Mic control
  'Unmute',             // Mic control alternative
  'Share screen',       // Screen sharing
  'Turn on video',      // Camera control
  'Turn off video',     // Camera control alternative
  'huddle',             // lowercase variant in UI text
];

// NOTE: Slack huddle keywords overlap significantly with regular Slack UI
// (channel descriptions may contain "huddle" in text). Must check for
// CONTROL elements, not just text presence.
```

**Slack huddle detection challenge:**
Slack's single-page app makes DOM detection harder because:
- URL does not change when huddle starts/ends
- Huddle UI is an overlay/floating window within the existing page
- Must detect the APPEARANCE of huddle-specific DOM elements
- MutationObserver is particularly valuable for Slack

```javascript
// Slack-specific detection: watch for huddle container appearing
function watchForSlackHuddle() {
  const observer = new MutationObserver((mutations) => {
    for (const mutation of mutations) {
      for (const node of mutation.addedNodes) {
        if (node.nodeType === Node.ELEMENT_NODE) {
          if (node.classList?.contains('p-huddle_window') ||
              node.querySelector?.('.p-huddle_window') ||
              node.querySelector?.('[aria-label*="huddle"]')) {
            // Huddle UI appeared
            reportMeetingDetected('slack');
          }
        }
      }
    }
  });

  observer.observe(document.body, { childList: true, subtree: true });
}
```

---

### 3.5 Amazon Chime Web

**URL Patterns:**
```
*://app.chime.aws/*
```

Note: Amazon Chime service is scheduled to end February 20, 2026. Support may be limited.

**Tab Title Patterns:**

| State | Title Format | Notes |
|-------|-------------|-------|
| Normal Chime | `"Amazon Chime"` | Home/chat view |
| In meeting | `"[Meeting Title] - Amazon Chime"` or `"Meeting - Amazon Chime"` | NEEDS VALIDATION |
| Post-meeting | `"Amazon Chime"` | Reverts to normal |

**DOM Signals (require live validation -- NO public DOM documentation exists):**

| Signal | Selector / Detection | Confidence | Notes |
|--------|---------------------|------------|-------|
| Meeting controls | Common patterns: `.video-tile`, `#participant-list`, `.mute-button` | LOW | Guesses based on similar apps; MUST validate live |
| Leave button | `button[aria-label*="Leave"]` | MEDIUM | Standard pattern |
| Mute button | `button[aria-label*="Mute"]` | MEDIUM | Standard pattern |
| Screen share | `button[aria-label*="Share"]` or `button[aria-label*="Screen"]` | LOW | Needs validation |

**Recommended textContent keywords for Chime:**
```javascript
const CHIME_ACTIVE_KEYWORDS = [
  'Leave',             // Leave meeting
  'End',               // End meeting (host)
  'Mute',              // Audio control
  'Unmute',            // Audio control
  'Video',             // Camera control
  'Share',             // Screen share
  'Attendees',         // Participant list
];
```

**Critical note:** Amazon Chime web DOM has zero public documentation. All selectors above are inferred from common patterns in meeting applications. Live validation during an actual Chime meeting is REQUIRED before implementation. Given the February 2026 end-of-service date, minimal investment in Chime-specific detection is recommended.

**Chime SDK vs Chime App:** The Amazon Chime SDK (github.com/aws/amazon-chime-sdk-js) is a developer SDK for BUILDING meeting applications. It does NOT document the `app.chime.aws` web app DOM. These are separate products.

---

## 4. Two-Tier Detection Strategy Implementation

### Overview

The two-tier approach minimizes resource usage by avoiding expensive DOM inspection unless cheap signals suggest a meeting is likely present.

```
Tier 1 (Cheap - Service Worker)          Tier 2 (Deep - Content Script / executeScript)
├── Tab URL matching                      ├── textContent keyword scanning
├── Tab title pattern matching            ├── CSS selector checks for meeting controls
├── Tab audible state                     ├── iframe presence detection
└── Tab created/removed events            ├── MutationObserver for DOM changes
                                          └── Meeting state classification
```

### Tier 1: URL and Title Monitoring (Service Worker)

```javascript
// =============================================================
// Tier 1: Cheap monitoring via chrome.tabs API
// Runs in service worker, costs essentially nothing
// =============================================================

const MEETING_URL_PATTERNS = {
  'google-meet':  /^https:\/\/meet\.google\.com\/.+/,
  'teams':        /^https:\/\/teams\.(microsoft\.com|live\.com|cloud\.microsoft)\/.*/,
  'zoom':         /^https:\/\/(app\.)?zoom\.us\/(wc|j)\/.*/,
  'slack':        /^https:\/\/app\.slack\.com\/.*/,
  'chime':        /^https:\/\/app\.chime\.aws\/.*/,
};

const MEETING_TITLE_SIGNALS = {
  'google-meet': {
    active:  [/Google Meet/i, /participants\s*\(\d+\)/i],
    ended:   [/left the meeting/i, /Meeting ended/i],
  },
  'teams': {
    active:  [/Microsoft Teams/i, /Meeting with/i, /Call with/i],
    ended:   [/Call ended/i],
  },
  'zoom': {
    active:  [/Zoom Meeting/i, /Zoom Webinar/i],
    ended:   [/Meeting Ended/i],
  },
  'slack': {
    active:  [/Slack/i],  // Slack title alone is NOT sufficient -- always needs Tier 2
    ended:   [],
  },
  'chime': {
    active:  [/Amazon Chime/i],
    ended:   [],
  },
};

// State tracking
const meetingCandidates = new Map(); // tabId -> { platform, url, title, tier1Time }
const confirmedMeetings = new Map(); // tabId -> { platform, url, title, tier2Time }

// ---- Tier 1 Entry Point ----
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (!tab.url) return;

  const platform = detectPlatformFromUrl(tab.url);
  if (!platform) {
    // Tab is not on a meeting platform -- check if it WAS a meeting
    if (confirmedMeetings.has(tabId)) {
      handleMeetingEnded(tabId, 'navigated_away');
    }
    return;
  }

  // Check for "ended" title signals
  const endedSignals = MEETING_TITLE_SIGNALS[platform]?.ended || [];
  const title = tab.title || '';
  if (endedSignals.some(regex => regex.test(title))) {
    if (confirmedMeetings.has(tabId)) {
      handleMeetingEnded(tabId, 'title_ended');
    }
    return;
  }

  // Tier 1 match: URL matches a meeting platform
  if (!meetingCandidates.has(tabId) && !confirmedMeetings.has(tabId)) {
    meetingCandidates.set(tabId, {
      platform,
      url: tab.url,
      title: title,
      tier1Time: Date.now(),
      audible: tab.audible || false
    });
  }

  // Request Tier 2 inspection
  requestTier2Inspection(tabId, platform);
});

chrome.tabs.onRemoved.addListener((tabId) => {
  if (confirmedMeetings.has(tabId)) {
    handleMeetingEnded(tabId, 'tab_closed');
  }
  meetingCandidates.delete(tabId);
});

function detectPlatformFromUrl(url) {
  for (const [platform, regex] of Object.entries(MEETING_URL_PATTERNS)) {
    if (regex.test(url)) return platform;
  }
  return null;
}
```

### Tier 2: DOM Inspection (Content Script or executeScript)

```javascript
// =============================================================
// Tier 2: Deep DOM inspection
// Only runs when Tier 1 identifies a candidate tab
// =============================================================

async function requestTier2Inspection(tabId, platform) {
  try {
    const results = await chrome.scripting.executeScript({
      target: { tabId: tabId },
      func: inspectMeetingDOM,
      args: [platform]
    });

    const domState = results[0]?.result;
    if (!domState) return;

    if (domState.isInMeeting) {
      if (!confirmedMeetings.has(tabId)) {
        // New meeting detected
        confirmedMeetings.set(tabId, {
          platform: platform,
          url: domState.url,
          title: domState.title,
          tier2Time: Date.now(),
          keywords: domState.matchedKeywords
        });
        meetingCandidates.delete(tabId);

        sendMessage({
          type: 'meeting_detected',
          platform: platform,
          tab_id: tabId,
          title: domState.title,
          url: domState.url,
          confidence: domState.confidence,
          signals: domState.matchedKeywords
        });
      }
    } else if (confirmedMeetings.has(tabId)) {
      // Was in meeting, signals gone -- potential end
      // Apply debounce before declaring ended
      scheduleEndCheck(tabId, platform);
    }

  } catch (err) {
    console.warn(`Tier 2 inspection failed for tab ${tabId}:`, err.message);
  }
}

// This function runs in the page context via executeScript
function inspectMeetingDOM(platform) {
  const bodyText = document.body?.textContent || '';
  const title = document.title || '';
  const url = location.href;

  // Platform-specific keyword sets
  const KEYWORDS = {
    'google-meet': {
      active: ['Leave call', 'Mute', 'Turn off camera', 'Present now', 'Captions'],
      strong: ['Leave call'],  // If this is present, definitely in a meeting
      ended: ['You left the meeting', 'Meeting ended', 'Return to home screen']
    },
    'teams': {
      active: ['Leave', 'Hang up', 'Mute', 'Unmute', 'Share', 'Raise', 'More actions'],
      strong: ['Hang up', 'Leave'],
      ended: ['Call ended', 'You left the meeting', 'Meeting has ended']
    },
    'zoom': {
      active: ['Leave', 'End Meeting', 'Mute', 'Unmute', 'Start Video', 'Stop Video',
               'Share Screen', 'Participants'],
      strong: ['Leave', 'End Meeting'],
      ended: ['Meeting Ended', 'The host has ended the meeting']
    },
    'slack': {
      active: ['Leave', 'Mute', 'Unmute', 'Share screen', 'Turn on video', 'Turn off video'],
      strong: [],  // Slack needs selector-based detection, not just keywords
      ended: []
    },
    'chime': {
      active: ['Leave', 'End', 'Mute', 'Unmute', 'Video', 'Share', 'Attendees'],
      strong: ['Leave'],
      ended: []
    }
  };

  const config = KEYWORDS[platform] || KEYWORDS['google-meet'];

  // Check for ended signals first (takes priority)
  const endedMatches = config.ended.filter(kw => bodyText.includes(kw));
  if (endedMatches.length > 0) {
    return {
      isInMeeting: false,
      isEnded: true,
      title, url,
      matchedKeywords: endedMatches,
      confidence: 'high'
    };
  }

  // Check for active meeting keywords
  const activeMatches = config.active.filter(kw => bodyText.includes(kw));
  const strongMatches = config.strong.filter(kw => bodyText.includes(kw));

  // Selector-based checks (more reliable for some platforms)
  let selectorScore = 0;
  const selectorResults = [];

  const selectorChecks = {
    'google-meet': [
      { sel: 'button[aria-label="Leave call"]', weight: 3, name: 'leave-button' },
      { sel: '[data-meeting-code]', weight: 2, name: 'meeting-code' },
    ],
    'teams': [
      { sel: '[data-tid="call-controls"]', weight: 3, name: 'call-controls' },
      { sel: 'button[aria-label*="Leave"]', weight: 2, name: 'leave-button' },
      { sel: '[data-tid="leave-call-button"]', weight: 3, name: 'leave-tid' },
    ],
    'zoom': [
      { sel: 'button[aria-label="Leave"]', weight: 3, name: 'leave-button' },
      { sel: 'button[aria-label*="mute"]', weight: 1, name: 'mute-button' },
    ],
    'slack': [
      { sel: '.p-huddle_window', weight: 3, name: 'huddle-window' },
      { sel: '[aria-label*="huddle"]', weight: 2, name: 'huddle-label' },
      { sel: '.c-huddle_controls', weight: 3, name: 'huddle-controls' },
      { sel: 'button[aria-label*="Leave huddle"]', weight: 3, name: 'leave-huddle' },
    ],
    'chime': [
      { sel: 'button[aria-label*="Leave"]', weight: 3, name: 'leave-button' },
      { sel: 'button[aria-label*="Mute"]', weight: 1, name: 'mute-button' },
    ]
  };

  const checks = selectorChecks[platform] || [];
  for (const check of checks) {
    try {
      if (document.querySelector(check.sel)) {
        selectorScore += check.weight;
        selectorResults.push(check.name);
      }
    } catch (e) { /* invalid selector, skip */ }
  }

  // Check for meeting-specific iframes
  const iframes = Array.from(document.querySelectorAll('iframe'));
  const meetingIframes = iframes.filter(iframe => {
    const src = iframe.src || '';
    return src.includes('meet.google.com') ||
           src.includes('teams.microsoft.com') ||
           src.includes('zoom.us') ||
           src.includes('chime.aws');
  });

  // Scoring: determine if we are in a meeting
  // Strong keyword match = definitely in meeting
  // 2+ active keywords + selector match = likely in meeting
  // selector score >= 3 = likely in meeting

  let isInMeeting = false;
  let confidence = 'low';

  if (strongMatches.length > 0 || selectorScore >= 3) {
    isInMeeting = true;
    confidence = 'high';
  } else if (activeMatches.length >= 2 && selectorScore >= 1) {
    isInMeeting = true;
    confidence = 'medium';
  } else if (activeMatches.length >= 3) {
    isInMeeting = true;
    confidence = 'medium';
  } else if (meetingIframes.length > 0) {
    isInMeeting = true;
    confidence = 'medium';
  }

  return {
    isInMeeting,
    isEnded: false,
    title, url,
    matchedKeywords: activeMatches,
    selectorResults: selectorResults,
    selectorScore: selectorScore,
    iframeCount: meetingIframes.length,
    confidence: confidence
  };
}
```

### Iframe Presence Detection

Some meeting platforms may embed their meeting UI within iframes on other pages:

```javascript
// Check for meeting-specific iframes by src domain
function checkMeetingIframes() {
  const iframes = document.querySelectorAll('iframe');
  const meetingDomains = [
    'meet.google.com',
    'teams.microsoft.com',
    'teams.live.com',
    'app.zoom.us',
    'zoom.us',
    'app.chime.aws'
  ];

  const detected = [];
  for (const iframe of iframes) {
    const src = iframe.src || iframe.getAttribute('src') || '';
    for (const domain of meetingDomains) {
      if (src.includes(domain)) {
        detected.push({ domain, src, visible: isElementVisible(iframe) });
      }
    }
  }
  return detected;
}

function isElementVisible(el) {
  const rect = el.getBoundingClientRect();
  const style = window.getComputedStyle(el);
  return rect.width > 0 && rect.height > 0 &&
         style.display !== 'none' &&
         style.visibility !== 'hidden' &&
         parseFloat(style.opacity) > 0;
}
```

### Content Script with MutationObserver (Alternative to Polling)

For platforms where meetings can start/end without URL changes (especially Slack huddles), a persistent content script with MutationObserver is more efficient than polling:

```javascript
// content-script.js
// Injected into meeting platform pages via manifest content_scripts

(function() {
  const PLATFORM = detectPlatform();
  let lastReportedState = null;
  let debounceTimer = null;

  function detectPlatform() {
    const host = location.hostname;
    if (host === 'meet.google.com') return 'google-meet';
    if (host.includes('teams.microsoft.com') || host.includes('teams.live.com')) return 'teams';
    if (host.includes('zoom.us')) return 'zoom';
    if (host === 'app.slack.com') return 'slack';
    if (host === 'app.chime.aws') return 'chime';
    return null;
  }

  if (!PLATFORM) return;

  // Periodic DOM check (every 3 seconds)
  setInterval(() => {
    checkMeetingState();
  }, 3000);

  // MutationObserver for immediate detection of DOM changes
  const observer = new MutationObserver((mutations) => {
    // Debounce: don't fire on every tiny DOM change
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => {
      checkMeetingState();
    }, 500);
  });

  // Observe the entire document for structural changes
  if (document.body) {
    observer.observe(document.body, {
      childList: true,
      subtree: true,
      // attributes: false  -- too noisy, skip attribute changes
    });
  }

  function checkMeetingState() {
    const bodyText = document.body?.textContent || '';
    const title = document.title;

    // Quick keyword scan (same logic as Tier 2 but lighter)
    const state = quickMeetingCheck(PLATFORM, bodyText, title);

    // Only report if state changed
    const stateKey = state.isInMeeting ? 'active' : 'inactive';
    if (stateKey !== lastReportedState) {
      lastReportedState = stateKey;

      chrome.runtime.sendMessage({
        type: state.isInMeeting ? 'content_meeting_detected' : 'content_meeting_ended',
        platform: PLATFORM,
        title: title,
        url: location.href,
        confidence: state.confidence,
        signals: state.signals
      });
    }
  }

  function quickMeetingCheck(platform, bodyText, title) {
    // Simplified check for content script polling
    // Full check done via executeScript in Tier 2

    const strongSignals = {
      'google-meet': ['Leave call'],
      'teams': ['Hang up'],
      'zoom': ['End Meeting'],
      'slack': [],
      'chime': []
    };

    const signals = strongSignals[platform] || [];
    const found = signals.filter(s => bodyText.includes(s));

    // For Slack: check selector instead
    if (platform === 'slack') {
      const huddleWindow = document.querySelector('.p-huddle_window, [aria-label*="huddle"], .c-huddle_controls');
      if (huddleWindow) {
        return { isInMeeting: true, confidence: 'high', signals: ['huddle-dom-element'] };
      }
    }

    if (found.length > 0) {
      return { isInMeeting: true, confidence: 'high', signals: found };
    }

    // Weaker signals
    const weakSignals = ['Mute', 'Unmute'];
    const weakFound = weakSignals.filter(s => bodyText.includes(s));
    if (weakFound.length > 0) {
      return { isInMeeting: true, confidence: 'low', signals: weakFound };
    }

    return { isInMeeting: false, confidence: 'high', signals: [] };
  }
})();
```

---

## 5. Robustness Considerations

### Service Worker Lifecycle

**Chrome MV3 Service Worker Behavior:**
- Service worker becomes inactive after 30 seconds of no extension events
- With an active WebSocket exchanging messages every 20 seconds, the service worker stays alive indefinitely
- If the WebSocket connection drops and no other events occur, the service worker will suspend within 30 seconds
- On suspension: all JavaScript state is lost (variables, timers, intervals)
- On wake: the service worker script re-executes from the top
- Event listeners registered synchronously at the top level survive across wake cycles

**What survives suspension:**
- `chrome.storage.local` data
- `chrome.alarms` scheduled alarms
- Event listener registrations (if registered at top level)
- Content scripts in tabs (they are independent of the service worker)

**What does NOT survive suspension:**
- JavaScript variables, objects, Maps, Sets
- WebSocket connections
- `setInterval` / `setTimeout` timers
- In-progress `fetch()` calls (may be interrupted)

### Alarms API for Periodic Polling

```javascript
// Register at top level (survives service worker restarts)
chrome.alarms.create('meeting-poll', { periodInMinutes: 0.5 }); // Every 30 seconds
chrome.alarms.create('reconnect-check', { periodInMinutes: 0.5 }); // Every 30 seconds

chrome.alarms.onAlarm.addListener(async (alarm) => {
  switch (alarm.name) {
    case 'meeting-poll':
      // Re-scan all meeting candidate tabs
      await scanAllTabsForMeetings();
      break;

    case 'reconnect-check':
      // Ensure WebSocket is connected
      ensureWebSocketConnected();
      break;
  }
});

async function scanAllTabsForMeetings() {
  // Restore state from storage if needed
  const stored = await chrome.storage.local.get(['confirmedMeetings', 'meetingCandidates']);

  // Query all tabs on meeting platforms
  const meetingTabs = await chrome.tabs.query({
    url: [
      '*://meet.google.com/*',
      '*://teams.microsoft.com/*',
      '*://teams.live.com/*',
      '*://app.zoom.us/*',
      '*://zoom.us/wc/*',
      '*://app.slack.com/*',
      '*://app.chime.aws/*'
    ]
  });

  for (const tab of meetingTabs) {
    const platform = detectPlatformFromUrl(tab.url);
    if (platform) {
      await requestTier2Inspection(tab.id, platform);
    }
  }

  // Check for meetings that have disappeared (tab closed while SW was suspended)
  const currentTabIds = new Set(meetingTabs.map(t => t.id));
  const previousMeetings = stored.confirmedMeetings || {};

  for (const tabIdStr of Object.keys(previousMeetings)) {
    const tabId = parseInt(tabIdStr);
    if (!currentTabIds.has(tabId)) {
      // Tab no longer exists -- meeting ended while we were suspended
      handleMeetingEnded(tabId, 'tab_gone_on_poll');
    }
  }
}
```

### Reconnection Strategy When Service Worker Restarts

```javascript
// === TOP LEVEL: Runs every time service worker starts ===

// 1. Restore state from storage
let activeMeetingsCache = new Map();

async function restoreState() {
  const stored = await chrome.storage.local.get([
    'confirmedMeetings',
    'reconnectAttempts'
  ]);

  if (stored.confirmedMeetings) {
    for (const [tabId, meeting] of Object.entries(stored.confirmedMeetings)) {
      activeMeetingsCache.set(parseInt(tabId), meeting);
    }
  }

  return stored.reconnectAttempts || 0;
}

async function persistState() {
  const meetingsObj = {};
  for (const [tabId, meeting] of activeMeetingsCache) {
    meetingsObj[tabId] = meeting;
  }
  await chrome.storage.local.set({
    confirmedMeetings: meetingsObj
  });
}

// 2. Connect WebSocket immediately on startup
restoreState().then(() => {
  connectWebSocket();
});

// 3. Register all event listeners at top level (synchronously)
chrome.tabs.onUpdated.addListener(handleTabUpdated);
chrome.tabs.onRemoved.addListener(handleTabRemoved);
chrome.alarms.onAlarm.addListener(handleAlarm);
chrome.runtime.onMessage.addListener(handleContentScriptMessage);
chrome.runtime.onInstalled.addListener(handleInstalled);
chrome.runtime.onStartup.addListener(handleStartup);
```

### Background Tab Behavior

Content scripts continue running in background (non-focused) tabs. This is critical for meeting detection because:

1. User joins a Google Meet call in one tab
2. User switches to another tab to take notes or work
3. The meeting tab is now a "background tab"
4. The content script in the meeting tab continues running
5. DOM polling and MutationObserver continue to detect meeting state
6. `chrome.runtime.sendMessage()` from content script to service worker continues to work

**Confirmed:** Content scripts are NOT throttled or suspended in background tabs. They have full DOM access and JavaScript execution. Only `setTimeout`/`setInterval` may be throttled to 1-second minimum intervals in background tabs (standard browser throttling), which is acceptable for 3-second polling.

### Edge Cases and Recovery

```
Scenario                          | Recovery Strategy
----------------------------------|----------------------------------------------------
Service worker suspended           | Alarms wake it; reconnects WebSocket; rescans tabs
WebSocket to host app drops        | Exponential backoff reconnect (1s, 2s, 4s... 30s max)
Host macOS app not running         | Extension keeps trying to connect; WebSocket fails
                                   | silently; detection continues locally; events queued
Tab navigates away from meeting    | chrome.tabs.onUpdated fires with new URL; Tier 1
                                   | detects non-meeting URL; triggers meeting_ended
Browser sleep/wake                 | Alarms fire on wake; full rescan; state reconciliation
Meeting platform updates DOM       | textContent scanning is resilient; selector checks
                                   | may fail but keyword checks continue working
Content script injection fails     | Service worker catches error; falls back to
                                   | Tier 1 (URL/title) only for that tab
Multiple meetings simultaneously   | Each tab tracked independently by tab_id
Extension updated while meetings   | chrome.runtime.onInstalled fires; full rescan
active                             |
```

---

## 6. WebSocket Message Protocol Design

### Extension to Host App Messages

```json
// Meeting detected (Tier 2 confirmed)
{
  "type": "meeting_detected",
  "platform": "google-meet",
  "tab_id": 123,
  "title": "Weekly Standup - Google Meet",
  "url": "https://meet.google.com/abc-defg-hij",
  "confidence": "high",
  "signals": ["Leave call", "Mute", "Turn off camera"],
  "timestamp": 1707235200000
}

// Meeting ended
{
  "type": "meeting_ended",
  "platform": "google-meet",
  "tab_id": 123,
  "reason": "title_ended",
  "timestamp": 1707238800000
}

// Periodic heartbeat (every 20 seconds, doubles as WebSocket keepalive)
{
  "type": "heartbeat",
  "active_meetings": [
    {
      "platform": "google-meet",
      "tab_id": 123,
      "title": "Weekly Standup - Google Meet",
      "confidence": "high"
    }
  ],
  "timestamp": 1707235220000
}

// Extension started/restarted
{
  "type": "extension_ready",
  "version": "1.0.0",
  "browser": "Comet",
  "active_meetings": [],
  "timestamp": 1707235200000
}

// Meeting state update (confidence or title changed)
{
  "type": "meeting_updated",
  "platform": "teams",
  "tab_id": 456,
  "title": "Meeting with John - Microsoft Teams",
  "confidence": "high",
  "signals": ["Hang up", "Mute", "Share"],
  "timestamp": 1707235400000
}
```

### Host App to Extension Messages

```json
// Acknowledge meeting detection
{
  "type": "ack",
  "event": "meeting_detected",
  "tab_id": 123,
  "status": "recording_started",
  "timestamp": 1707235200500
}

// Request current state (e.g., after host app restart)
{
  "type": "status_request",
  "timestamp": 1707235200000
}

// Configuration update
{
  "type": "config",
  "poll_interval_ms": 3000,
  "platforms_enabled": ["google-meet", "teams", "zoom", "slack", "chime"],
  "timestamp": 1707235200000
}

// Force rescan (e.g., after host app recovers from error)
{
  "type": "rescan",
  "timestamp": 1707235200000
}
```

### Message Handling in Service Worker

```javascript
function handleHostMessage(msg) {
  switch (msg.type) {
    case 'ack':
      console.log(`Host acknowledged ${msg.event} for tab ${msg.tab_id}: ${msg.status}`);
      // Update internal state if needed
      break;

    case 'status_request':
      // Respond with current meeting state
      sendMessage({
        type: 'heartbeat',
        active_meetings: getActiveMeetingsSummary(),
        timestamp: Date.now()
      });
      break;

    case 'config':
      // Update detection configuration
      chrome.storage.local.set({ hostConfig: msg });
      break;

    case 'rescan':
      // Force immediate rescan of all tabs
      scanAllTabsForMeetings();
      break;

    default:
      console.warn('Unknown message type from host:', msg.type);
  }
}

function getActiveMeetingsSummary() {
  const meetings = [];
  for (const [tabId, meeting] of activeMeetingsCache) {
    meetings.push({
      platform: meeting.platform,
      tab_id: tabId,
      title: meeting.title,
      confidence: meeting.confidence || 'unknown'
    });
  }
  return meetings;
}

// Debounced meeting end handling
const endTimers = new Map();

function scheduleEndCheck(tabId, platform) {
  // Cancel existing timer for this tab
  if (endTimers.has(tabId)) {
    clearTimeout(endTimers.get(tabId));
  }

  // Wait 10 seconds before declaring meeting ended
  // (handles brief signal drops, page reloads, momentary disconnects)
  const timer = setTimeout(async () => {
    endTimers.delete(tabId);

    // Re-check one more time
    const stillInMeeting = await requestTier2Inspection(tabId, platform);
    if (!stillInMeeting) {
      handleMeetingEnded(tabId, 'signals_gone');
    }
  }, 10000); // 10 second debounce (configurable)

  endTimers.set(tabId, timer);
}

function handleMeetingEnded(tabId, reason) {
  const meeting = activeMeetingsCache.get(tabId);
  if (!meeting) return;

  activeMeetingsCache.delete(tabId);
  persistState();

  if (endTimers.has(tabId)) {
    clearTimeout(endTimers.get(tabId));
    endTimers.delete(tabId);
  }

  sendMessage({
    type: 'meeting_ended',
    platform: meeting.platform,
    tab_id: tabId,
    reason: reason,
    timestamp: Date.now()
  });
}
```

### Protocol Design Rationale

1. **Heartbeat doubles as keepalive:** The 20-second heartbeat interval keeps both the WebSocket alive AND provides the host app with current state. If the host app misses a `meeting_detected` event (e.g., it was restarting), the next heartbeat will include the active meeting in `active_meetings`.

2. **Stateless polling model:** The heartbeat always contains the complete list of active meetings. The host app can reconstruct full state from any single heartbeat. This aligns with the "stateless polling" principle from the brainstorming session -- self-healing through any disruption.

3. **Debounced end detection:** Meetings are not declared ended immediately when signals disappear. A 10-second grace period handles brief DOM changes, page reloads, and signal flickers. This implements the "fail long" principle.

4. **Tab ID as meeting identifier:** Each browser tab has a unique `tab_id` that persists for the tab's lifetime. This naturally handles multiple simultaneous meetings (different tabs) and distinguishes between meeting sessions.

5. **Confidence levels:** The `confidence` field lets the host app make graduated decisions. A `high` confidence meeting detection might auto-start recording, while a `low` confidence detection might require additional confirmation (e.g., waiting for `medium` or `high` on the next poll).

---

## Summary: What Needs Live Validation

| Item | Why | How to Validate |
|------|-----|----------------|
| Google Meet CSS selectors | DOM changes with updates | Join a test meeting, inspect with DevTools |
| Google Meet tab title format | Format may vary by language/region | Observe actual titles during meetings |
| Teams `data-tid` attributes | May change between Teams versions | Inspect during active Teams web call |
| Teams Shadow DOM presence | 2025 Wave 1 may have changed this | Check `element.shadowRoot` in DevTools |
| Zoom web client selectors | Heavily obfuscated, no documentation | Join Zoom web meeting, inspect DOM |
| Zoom web client availability | Zoom pushes users to native app | Confirm web client is accessible |
| Slack huddle DOM elements | `.p-huddle_window` class may change | Start a Slack huddle, inspect DOM |
| Slack tab title during huddle | May or may not change | Observe actual title during huddle |
| Chime web DOM (all selectors) | Zero documentation available | Join a Chime meeting, inspect DOM |
| WebSocket in Comet browser | Chrome 116+ is confirmed; Comet needs testing | Test WebSocket from Comet service worker |
| Content script CSP on each platform | Each platform's CSP may differ | Check `connect-src` in response headers |
| `textContent` keyword reliability | Keywords may differ by language | Test with English locale meetings |
| Service worker keepalive timing | 30s documented but may vary in Comet | Long-running test with WebSocket |
| Background tab throttling | `setInterval` may be throttled | Time actual intervals in background tab |

---

## Appendix: Complete manifest.json

```json
{
  "manifest_version": 3,
  "name": "MacWhisperAuto Meeting Detector",
  "description": "Detects active browser-based meetings and reports to MacWhisperAuto host app",
  "version": "1.0.0",
  "minimum_chrome_version": "116",

  "permissions": [
    "tabs",
    "scripting",
    "alarms",
    "storage"
  ],

  "host_permissions": [
    "*://meet.google.com/*",
    "*://teams.microsoft.com/*",
    "*://teams.live.com/*",
    "*://teams.cloud.microsoft/*",
    "*://app.zoom.us/*",
    "*://zoom.us/wc/*",
    "*://zoom.us/j/*",
    "*://app.slack.com/*",
    "*://app.chime.aws/*"
  ],

  "background": {
    "service_worker": "background.js"
  },

  "content_scripts": [
    {
      "matches": [
        "*://meet.google.com/*",
        "*://teams.microsoft.com/*",
        "*://teams.live.com/*",
        "*://teams.cloud.microsoft/*",
        "*://app.zoom.us/*",
        "*://zoom.us/wc/*",
        "*://app.slack.com/*",
        "*://app.chime.aws/*"
      ],
      "js": ["content-script.js"],
      "run_at": "document_idle"
    }
  ],

  "icons": {
    "16": "icons/icon16.png",
    "48": "icons/icon48.png",
    "128": "icons/icon128.png"
  }
}
```

## Appendix: Comet Browser Compatibility Notes

Comet is a Chromium-based browser. Key considerations:

1. **Extension loading:** Load unpacked extension via Comet's extension management page (likely `comet://extensions` or similar Chromium-based URL)
2. **MV3 support:** As a Chromium browser, Comet should support MV3 fully. Verify `minimum_chrome_version` is compatible with Comet's Chromium version.
3. **WebSocket in service worker:** Must be tested explicitly. While Chrome 116+ supports this, Comet's Chromium fork version determines actual support.
4. **`chrome.*` API namespace:** Chromium browsers typically support the `chrome.*` namespace. Some may also support `browser.*` (Firefox-style). Use `chrome.*` for Chromium targets.
5. **Process name in MacWhisper:** MacWhisper's `meetingAppsToObserve` includes `comet`. The host app will use "Record Comet" button. The extension must report the browser identity so the host app knows which MacWhisper button to press.

## Appendix: File Structure for Extension

```
Extension/
├── manifest.json              # Extension manifest (MV3)
├── background.js              # Service worker: tabs API, WebSocket, state management
├── content-script.js          # Injected into meeting pages: DOM inspection, MutationObserver
├── detection/
│   ├── platforms.js           # Platform URL patterns and keyword configs
│   ├── google-meet.js         # Google Meet-specific selectors and detection logic
│   ├── teams.js               # Microsoft Teams-specific detection
│   ├── zoom.js                # Zoom-specific detection
│   ├── slack.js               # Slack-specific detection (huddle focus)
│   └── chime.js               # Amazon Chime-specific detection
├── lib/
│   ├── websocket-client.js    # WebSocket connection with reconnection logic
│   └── state-manager.js       # chrome.storage.local state persistence
└── icons/
    ├── icon16.png
    ├── icon48.png
    └── icon128.png
```
