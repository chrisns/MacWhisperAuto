// rules.js - User-defined meeting URL rules, shared by the service worker,
// content script and options page. Rules live in chrome.storage.local under
// CUSTOM_RULES_KEY and never ship with the extension.
//
// Rule shape:
//   { id, name, pattern, titleContains, source, enabled }
//   pattern       Chrome match pattern, e.g. "https://*.example.com/*"
//   titleContains case-insensitive text; meeting is active while the title contains it
//   source        MacWhisper record source: "" (auto: the browser this runs in), "Comet" or "Chrome"
//
// Only function declarations live here (no top-level const/let) so the file is
// safe to load more than once in the same isolated world.

function customRulesKey() {
  return 'customRules';
}

function macWhisperSources() {
  return ['Comet', 'Chrome'];
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// Turn user input into a valid match pattern, or null.
// "https://*.example.com" -> "https://*.example.com/*", "call.example.com" -> "https://call.example.com/*"
function normalizePattern(input) {
  if (typeof input !== 'string') return null;
  let text = input.trim();
  if (!text) return null;
  if (!text.includes('://')) text = `https://${text}`;

  const match = /^(\*|https?):\/\/([^/]+)(\/.*)?$/.exec(text);
  if (!match) return null;
  const [, scheme, host, path] = match;
  if (!/^(\*|(\*\.)?[a-z0-9.-]+)$/i.test(host)) return null;
  if (host !== '*' && host.replace(/^\*\./, '').startsWith('.')) return null;

  return `${scheme}://${host.toLowerCase()}${path || '/*'}`;
}

// Origin form of a pattern, as used by chrome.permissions ("https://*.example.com/*").
function patternOrigin(pattern) {
  const match = /^(\*|https?):\/\/([^/]+)/.exec(pattern || '');
  return match ? `${match[1]}://${match[2]}/*` : null;
}

function patternToRegExp(pattern) {
  const match = /^(\*|https?):\/\/([^/]+)(\/.*)$/.exec(pattern || '');
  if (!match) return null;
  const [, scheme, host, path] = match;

  const schemeRe = scheme === '*' ? 'https?' : escapeRegExp(scheme);
  let hostRe;
  if (host === '*') {
    hostRe = '[^/]+';
  } else if (host.startsWith('*.')) {
    hostRe = `(?:[^/]+\\.)?${escapeRegExp(host.slice(2))}`;
  } else {
    hostRe = escapeRegExp(host);
  }
  const pathRe = path.split('*').map(escapeRegExp).join('.*');

  return new RegExp(`^${schemeRe}://${hostRe}(?::\\d+)?${pathRe}$`, 'i');
}

function isUsableRule(rule) {
  return !!rule &&
    rule.enabled !== false &&
    !!normalizePattern(rule.pattern) &&
    typeof rule.titleContains === 'string' &&
    rule.titleContains.trim() !== '';
}

// All stored rules, including disabled ones (for the options page).
async function loadAllCustomRules() {
  const result = await chrome.storage.local.get(customRulesKey());
  const rules = result[customRulesKey()];
  return Array.isArray(rules) ? rules : [];
}

// Enabled, valid rules only.
async function loadCustomRules() {
  return (await loadAllCustomRules()).filter(isUsableRule);
}

function findCustomRule(rules, url) {
  if (!url) return null;
  const target = url.split('#')[0];
  for (const rule of rules || []) {
    if (!isUsableRule(rule)) continue;
    const re = patternToRegExp(normalizePattern(rule.pattern));
    if (re && re.test(target)) return rule;
  }
  return null;
}

function customRuleIsActive(rule, title) {
  if (!rule || typeof title !== 'string') return false;
  return title.toLowerCase().includes(rule.titleContains.trim().toLowerCase());
}
