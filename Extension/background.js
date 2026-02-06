// background.js - MV3 Service Worker for MacWhisperAuto Meeting Detection

const LOG_PREFIX = '[MacWhisperAuto]';
const WEBSOCKET_URL = 'ws://127.0.0.1:8765';
const KEEPALIVE_INTERVAL_MS = 20000;
const RECONNECT_BASE_MS = 1000;
const RECONNECT_MAX_MS = 30000;
const EXTENSION_VERSION = '1.0.0';

const MEETING_PATTERNS = {
  google_meet: /^https:\/\/meet\.google\.com\/[a-z]{3}-[a-z]{4}-[a-z]{3}/,
  teams_web: /^https:\/\/teams\.microsoft\.com\/.*(meeting|call)/i,
  zoom_web: /^https:\/\/[a-z0-9]+\.zoom\.us\/(j|wc)\//,
  slack_huddle: /^https:\/\/app\.slack\.com\/huddle\//,
  chime_web: /^https:\/\/app\.chime\.aws\/.*(meeting|call)/i
};

// --- State ---

// Map<tabId, { platform, url, title, detected_at }>
const activeMeetings = new Map();

let ws = null;
let reconnectAttempts = 0;
let keepaliveTimerId = null;

// --- Logging ---

function log(...args) {
  console.log(LOG_PREFIX, ...args);
}

function warn(...args) {
  console.warn(LOG_PREFIX, ...args);
}

function error(...args) {
  console.error(LOG_PREFIX, ...args);
}

// --- URL Matching ---

function matchPlatform(url) {
  if (!url) return null;
  for (const [platform, pattern] of Object.entries(MEETING_PATTERNS)) {
    if (pattern.test(url)) return platform;
  }
  return null;
}

// --- WebSocket ---

function connectWebSocket() {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
    return;
  }

  log('Connecting to WebSocket:', WEBSOCKET_URL);

  try {
    ws = new WebSocket(WEBSOCKET_URL);
  } catch (err) {
    error('WebSocket constructor failed:', err.message);
    scheduleReconnect();
    return;
  }

  ws.onopen = () => {
    log('WebSocket connected');
    reconnectAttempts = 0;
    startKeepalive();
    sendHeartbeat();
  };

  ws.onclose = (event) => {
    log('WebSocket closed:', event.code, event.reason);
    stopKeepalive();
    ws = null;
    scheduleReconnect();
  };

  ws.onerror = (event) => {
    warn('WebSocket error');
    // onclose will fire after onerror, so reconnect is handled there
  };

  ws.onmessage = (event) => {
    log('WebSocket message received:', event.data);
    // Host app may send commands in future; for now just log
  };
}

function scheduleReconnect() {
  const delayMs = Math.min(
    RECONNECT_BASE_MS * Math.pow(2, reconnectAttempts),
    RECONNECT_MAX_MS
  );
  reconnectAttempts++;
  log(`Reconnecting in ${delayMs}ms (attempt ${reconnectAttempts})`);
  setTimeout(connectWebSocket, delayMs);
}

function sendMessage(msg) {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    warn('WebSocket not open, queuing not implemented - message dropped');
    return false;
  }
  try {
    ws.send(JSON.stringify(msg));
    return true;
  } catch (err) {
    error('WebSocket send failed:', err.message);
    return false;
  }
}

// --- Keepalive / Heartbeat ---

function startKeepalive() {
  stopKeepalive();
  keepaliveTimerId = setInterval(sendHeartbeat, KEEPALIVE_INTERVAL_MS);
}

function stopKeepalive() {
  if (keepaliveTimerId !== null) {
    clearInterval(keepaliveTimerId);
    keepaliveTimerId = null;
  }
}

function sendHeartbeat() {
  const meetings = [];
  for (const [tabId, info] of activeMeetings) {
    meetings.push({
      tab_id: tabId,
      platform: info.platform,
      url: info.url,
      title: info.title,
      detected_at: info.detected_at
    });
  }

  sendMessage({
    type: 'heartbeat',
    active_meetings: meetings,
    extension_version: EXTENSION_VERSION,
    timestamp: new Date().toISOString()
  });
}

// --- Persistence (FR35) ---

function persistMeetings() {
  const data = {};
  for (const [tabId, info] of activeMeetings) {
    data[tabId] = info;
  }
  chrome.storage.local.set({ activeMeetings: data });
}

async function restoreMeetings() {
  try {
    const result = await chrome.storage.local.get('activeMeetings');
    const stored = result.activeMeetings;
    if (!stored || typeof stored !== 'object') return;

    for (const [tabId, info] of Object.entries(stored)) {
      const id = parseInt(tabId, 10);
      if (isNaN(id)) continue;
      // Verify the tab still exists and URL still matches
      try {
        const tab = await chrome.tabs.get(id);
        const platform = matchPlatform(tab.url);
        if (platform) {
          activeMeetings.set(id, {
            platform: info.platform,
            url: tab.url,
            title: tab.title || info.title,
            detected_at: info.detected_at
          });
          log(`Restored meeting: ${info.platform} in tab ${id}`);
        }
      } catch {
        // Tab no longer exists, skip
      }
    }
    log(`Restored ${activeMeetings.size} meeting(s) from storage`);
  } catch (err) {
    warn('Failed to restore meetings from storage:', err.message);
  }
}

// --- Meeting State ---

function addMeeting(tabId, platform, url, title) {
  const existing = activeMeetings.get(tabId);
  if (existing && existing.platform === platform) {
    // Update title/url if changed but keep detected_at
    existing.url = url;
    existing.title = title;
    persistMeetings();
    return;
  }

  const now = new Date().toISOString();
  activeMeetings.set(tabId, {
    platform,
    url,
    title,
    detected_at: now
  });

  log(`Meeting detected: ${platform} in tab ${tabId} - ${title}`);
  persistMeetings();

  sendMessage({
    type: 'meeting_detected',
    tab_id: tabId,
    platform,
    url,
    title,
    timestamp: now
  });
}

function removeMeeting(tabId) {
  const meeting = activeMeetings.get(tabId);
  if (!meeting) return;

  activeMeetings.delete(tabId);
  log(`Meeting ended: ${meeting.platform} in tab ${tabId}`);
  persistMeetings();

  sendMessage({
    type: 'meeting_ended',
    tab_id: tabId,
    platform: meeting.platform,
    url: meeting.url,
    title: meeting.title,
    timestamp: new Date().toISOString()
  });
}

// --- Tab Events ---

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  // Only act on URL changes or completion
  if (!changeInfo.url && changeInfo.status !== 'complete') return;

  const url = changeInfo.url || tab.url;
  const platform = matchPlatform(url);

  if (platform) {
    log(`Tab ${tabId} updated: potential ${platform} meeting - ${url}`);
    // Don't add yet - wait for content script confirmation
    // But if URL no longer matches a meeting pattern, remove
  } else if (activeMeetings.has(tabId)) {
    // Tab navigated away from a meeting URL
    log(`Tab ${tabId} navigated away from meeting`);
    removeMeeting(tabId);
  }
});

chrome.tabs.onRemoved.addListener((tabId) => {
  if (activeMeetings.has(tabId)) {
    log(`Tab ${tabId} closed`);
    removeMeeting(tabId);
  }
});

// --- Content Script Messages ---

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!sender.tab) {
    warn('Message from non-tab context, ignoring');
    return;
  }

  const tabId = sender.tab.id;

  switch (message.type) {
    case 'meeting_detected': {
      addMeeting(tabId, message.platform, message.url, message.title);
      sendResponse({ ok: true });
      break;
    }
    case 'meeting_ended': {
      removeMeeting(tabId);
      sendResponse({ ok: true });
      break;
    }
    case 'meeting_status': {
      // Content script reporting periodic status
      if (message.is_active) {
        addMeeting(tabId, message.platform, message.url, message.title);
      } else {
        removeMeeting(tabId);
      }
      sendResponse({ ok: true });
      break;
    }
    default:
      warn('Unknown message type:', message.type);
      sendResponse({ ok: false, error: 'unknown_type' });
  }
});

// --- MV3 Service Worker Keepalive ---
// Use chrome.alarms to periodically wake the service worker so it can
// maintain the WebSocket connection and re-scan tabs.

chrome.alarms.create('keepalive', { periodInMinutes: 0.4 }); // ~24s

chrome.alarms.onAlarm.addListener(async (alarm) => {
  if (alarm.name === 'keepalive') {
    // Restore state if service worker was suspended and lost in-memory state
    if (activeMeetings.size === 0) {
      await restoreMeetings();
    }
    // If WebSocket died, reconnect
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      connectWebSocket();
    }
  }
});

// --- Startup ---

log('Service worker starting, version', EXTENSION_VERSION);

// Restore state from storage (FR35), then connect and send heartbeat
restoreMeetings().then(() => {
  connectWebSocket();
});
