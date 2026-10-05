// options.js - Edit user-defined meeting rules (stored by rules.js helpers)

const rowsEl = document.getElementById('rules');
const emptyEl = document.getElementById('empty');
const statusEl = document.getElementById('status');
const rowTemplate = document.getElementById('row');

function newRuleId() {
  return `rule-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

function setStatus(text, isError = false) {
  statusEl.textContent = text;
  statusEl.classList.toggle('error', isError);
}

function updateEmptyState() {
  emptyEl.hidden = rowsEl.children.length > 0;
}

function addRow(rule = {}) {
  const row = rowTemplate.content.firstElementChild.cloneNode(true);
  row.dataset.id = rule.id || newRuleId();

  const field = (name) => row.querySelector(`[name="${name}"]`);
  const source = field('source');
  for (const value of ['', ...macWhisperSources()]) {
    const option = document.createElement('option');
    option.value = value;
    option.textContent = value || 'Auto (this browser)';
    source.appendChild(option);
  }

  field('name').value = rule.name || '';
  field('pattern').value = rule.pattern || '';
  field('titleContains').value = rule.titleContains || '';
  source.value = macWhisperSources().includes(rule.source) ? rule.source : '';
  field('enabled').checked = rule.enabled !== false;
  field('remove').addEventListener('click', () => {
    row.remove();
    updateEmptyState();
    setStatus('Removed. Click Save to apply.');
  });

  rowsEl.appendChild(row);
  updateEmptyState();
  return row;
}

// Read and validate the table. Returns null (and marks bad fields) on error.
function readRows() {
  const rules = [];
  let valid = true;
  for (const row of rowsEl.querySelectorAll('tr')) {
    const field = (name) => row.querySelector(`[name="${name}"]`);
    const pattern = normalizePattern(field('pattern').value);
    const titleContains = field('titleContains').value.trim();

    field('pattern').classList.toggle('invalid', !pattern);
    field('titleContains').classList.toggle('invalid', !titleContains);
    if (!pattern || !titleContains) {
      valid = false;
      continue;
    }

    field('pattern').value = pattern;
    rules.push({
      id: row.dataset.id,
      name: field('name').value.trim(),
      pattern,
      titleContains,
      source: field('source').value,
      enabled: field('enabled').checked
    });
  }
  return valid ? rules : null;
}

async function refreshPermissionBadges() {
  for (const row of rowsEl.querySelectorAll('tr')) {
    const badge = row.querySelector('.perm');
    const origin = patternOrigin(normalizePattern(row.querySelector('[name="pattern"]').value));
    if (!origin) {
      badge.textContent = '';
      badge.className = 'perm';
      continue;
    }
    const granted = await chrome.permissions.contains({ origins: [origin] });
    badge.textContent = granted ? 'Granted' : 'Not granted';
    badge.className = `perm ${granted ? 'ok' : 'missing'}`;
  }
}

// Drop optional host access that no rule needs any more.
async function removeUnusedPermissions(rules) {
  const needed = new Set(rules.map((rule) => patternOrigin(rule.pattern)));
  const required = new Set(chrome.runtime.getManifest().host_permissions || []);
  const { origins = [] } = await chrome.permissions.getAll();
  const unused = origins.filter((origin) => !needed.has(origin) && !required.has(origin));
  if (unused.length > 0) await chrome.permissions.remove({ origins: unused });
}

async function save() {
  const rules = readRows();
  if (!rules) {
    setStatus('Fix the fields marked in red. Each site needs a URL pattern and title text.', true);
    return;
  }

  // permissions.request must be the first await: it needs the click's user gesture.
  const origins = [...new Set(rules.filter((r) => r.enabled).map((r) => patternOrigin(r.pattern)))];
  let granted = true;
  if (origins.length > 0) {
    try {
      granted = await chrome.permissions.request({ origins });
    } catch (err) {
      setStatus(`Permission request failed: ${err.message}`, true);
      return;
    }
  }

  await chrome.storage.local.set({ [customRulesKey()]: rules });
  await removeUnusedPermissions(rules);
  await refreshPermissionBadges();

  if (granted) {
    setStatus('Saved. Reload open tabs for these sites.');
  } else {
    setStatus('Saved, but site access was not granted. The rules without access do nothing.', true);
  }
}

document.getElementById('add').addEventListener('click', () => {
  addRow().querySelector('[name="pattern"]').focus();
});
document.getElementById('save').addEventListener('click', save);

loadAllCustomRules().then(async (rules) => {
  for (const rule of rules) addRow(rule);
  updateEmptyState();
  await refreshPermissionBadges();
});
