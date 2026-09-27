/* ============================================================================
   run-ui-tests.mjs — real frontend UI tests for the VibeRouter console.

   Drives the ACTUAL served page in headless Chromium (Playwright) against an
   isolated backend (never the live :8318 instance):
     - logs in with the management key
     - visits every page in dark and light themes, asserts render + no crash
     - exercises the main flows: ⌘K palette, theme switch, add/remove access
       key (with the confirm dialog), account toggle + Undo, settings toggle,
       logs enable, models filter
     - checks no horizontal overflow at 320 / 375 / 414 / 768 px
     - screenshots to uitest/shots/

   Usage: node run-ui-tests.mjs <port> <key>
   ============================================================================ */
import { chromium } from 'playwright';
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const PORT = process.argv[2] || '8451';
const KEY = process.argv[3] || 'ui-test-key';
const BASE = `http://127.0.0.1:${PORT}`;
if (PORT === '8318') {
  console.error('Refusing to run mutating UI tests against the live backend (:8318). Use smoke-readonly.mjs.');
  process.exit(2);
}
const HERE = dirname(fileURLToPath(import.meta.url));
const SHOTS = join(HERE, 'shots');
mkdirSync(SHOTS, { recursive: true });

const results = [];
function record(name, ok, detail = '') {
  results.push({ name, ok, detail });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`);
}

const PAGES = [
  ['overview', 'Overview'],
  ['playground', 'Playground'],
  ['accounts', 'Accounts'],
  ['models', 'Models'],
  ['keys', 'API keys'],
  ['logs', 'Logs'],
  ['settings', 'Settings'],
];

async function waitToast(page, text) {
  const loc = text ? page.locator('.toast', { hasText: text }) : page.locator('.toast');
  return loc.first().waitFor({ timeout: 5000 }).then(() => true).catch(() => false);
}

async function main() {
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport: { width: 1360, height: 900 } });
  await ctx.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: BASE });
  const page = await ctx.newPage();

  const pageErrors = [];
  const consoleErrors = [];
  const httpFailures = [];
  page.on('pageerror', (err) => pageErrors.push(String(err)));
  page.on('console', (msg) => msg.type() === 'error' && consoleErrors.push(msg.text()));
  page.on('response', (r) => {
    if (r.status() >= 400) httpFailures.push(`${r.request().method()} ${new URL(r.url()).pathname} → ${r.status()}`);
  });

  // --- Load + login
  await page.goto(`${BASE}/management.html`, { waitUntil: 'networkidle' });
  record('page loads', true, await page.title());
  const favicon = await page.getAttribute('link[rel="icon"]', 'href').catch(() => null);
  record('favicon set (glyph)', !!favicon && favicon.startsWith('data:image/png'));

  await page.waitForSelector('.gate-card, .app', { timeout: 8000 });
  if (await page.$('#mgmt-key')) {
    await page.fill('#mgmt-key', 'wrong-key');
    await page.click('button:has-text("Unlock console")');
    const err = await page.waitForSelector('.gate-err:not(:empty)', { timeout: 5000 }).catch(() => null);
    record('login: wrong key shows inline error', !!err, err ? await err.textContent() : '');
    await page.fill('#mgmt-key', KEY);
    await page.click('button:has-text("Unlock console")');
  }
  await page.waitForSelector('.app', { timeout: 8000 });
  record('login with key', true);
  record('rail brand glyph', !!(await page.$('.rail .brand-mark img')));

  // --- Every page, both themes
  for (const theme of ['dark', 'light']) {
    await page.evaluate((t) => localStorage.setItem('vr_theme', t), theme);
    await page.reload({ waitUntil: 'networkidle' });
    await page.waitForSelector('.app');
    const applied = await page.evaluate(() => document.documentElement.dataset.theme);
    record(`theme ${theme} applied`, applied === theme, applied);
    for (const [path, label] of PAGES) {
      const before = pageErrors.length;
      await page.click(`.rail .nav-link:has-text("${label}")`);
      await page.waitForURL(`**#/${path}**`);
      await page.waitForTimeout(500);
      const view = await page.$('.view');
      record(`${theme}: ${label} renders`, !!view && pageErrors.length === before);
      await page.screenshot({ path: join(SHOTS, `${theme}-${path}.png`), fullPage: true });
    }
  }

  // --- Provider icons are real images
  await page.click('.rail .nav-link:has-text("Accounts")');
  await page.waitForTimeout(500);
  const imgs = await page.$$eval('.plogo img', (i) => i.length);
  record('provider logos render as images', imgs > 0, `${imgs} logos`);

  // --- Account toggle → optimistic + Undo
  const sw = page.locator('.list-row .switch').first();
  if (await sw.count()) {
    const before = await sw.getAttribute('aria-checked');
    await sw.click();
    const flipped = (await sw.getAttribute('aria-checked')) !== before;
    const hasUndo = await page.locator('.toast button:has-text("Undo")').first().waitFor({ timeout: 4000 }).then(() => true).catch(() => false);
    record('accounts: toggle flips immediately + offers Undo', flipped && hasUndo);
    if (hasUndo) {
      await page.click('.toast button:has-text("Undo")');
      await page.waitForTimeout(1200);
      record('accounts: Undo restores state', (await sw.getAttribute('aria-checked')) === before);
    }
  } else {
    record('accounts: toggle flips immediately + offers Undo', false, 'no account rows');
  }

  // --- Accounts filter chip → URL state
  await page.click('.chip:has-text("Active")');
  record('accounts: filter chip sets ?state=', page.url().includes('state=active'));

  // --- ⌘K palette → navigate
  await page.keyboard.press(process.platform === 'darwin' ? 'Meta+k' : 'Control+k');
  const palette = await page.waitForSelector('.cmdk', { timeout: 3000 }).catch(() => null);
  record('palette opens with ⌘K', !!palette);
  if (palette) {
    await page.keyboard.type('settings');
    await page.keyboard.press('Enter');
    const went = await page.waitForURL('**#/settings', { timeout: 4000 }).then(() => true).catch(() => false);
    record('palette navigates by search + Enter', went);
    await page.waitForSelector('button[role="switch"][aria-label="Debug output"]', { timeout: 6000 });
  }

  // --- Settings toggle → toast
  const debug = page.locator('button[role="switch"][aria-label="Debug output"]');
  const debugBefore = await debug.getAttribute('aria-checked');
  await debug.click();
  record('settings: toggle → toast', await waitToast(page, 'Debug output'));
  await page.waitForTimeout(400);
  await debug.click();
  await page.waitForTimeout(600);
  record('settings: toggle round-trips', (await debug.getAttribute('aria-checked')) === debugBefore);

  // --- Theme switch in rail
  await page.click('.rail .seg button:has-text("Dark")');
  const t1 = await page.evaluate(() => document.documentElement.dataset.theme);
  await page.click('.rail .seg button:has-text("Light")');
  const t2 = await page.evaluate(() => document.documentElement.dataset.theme);
  record('rail theme switch flips palette', t1 === 'dark' && t2 === 'light');

  // --- Keys: generate + add, then remove through the confirm dialog
  await page.click('.rail .nav-link:has-text("API keys")');
  await page.waitForTimeout(400);
  await page.click('button:has-text("Generate")');
  const generated = await page.inputValue('#new-key');
  record('keys: Generate fills a strong key', /^vr-[A-Za-z0-9_-]{30,}$/.test(generated), generated.slice(0, 6) + '…');
  await page.click('button:has-text("Add key")');
  const added = await waitToast(page, 'Key added');
  await page.waitForTimeout(500);
  const rows = await page.locator('section[aria-labelledby="access-title"] .list-row').count();
  record('keys: add → toast + row', added && rows > 0, `${rows} rows`);
  await page.locator('section[aria-labelledby="access-title"] .list-row .icon-btn.danger').first().click();
  const dialog = await page.waitForSelector('[role="alertdialog"]', { timeout: 3000 }).catch(() => null);
  record('keys: remove asks for confirmation', !!dialog);
  if (dialog) {
    await page.keyboard.press('Escape');
    record('keys: Esc cancels the dialog', !(await page.$('[role="alertdialog"]')));
    await page.locator('section[aria-labelledby="access-title"] .list-row .icon-btn.danger').first().click();
    await page.click('[role="alertdialog"] button:has-text("Remove key")');
    record('keys: confirmed remove → toast', await waitToast(page, 'Key removed'));
  }

  // --- Logs: enable from the empty state
  await page.click('.rail .nav-link:has-text("Logs")');
  await page.waitForTimeout(400);
  const enable = await page.$('button:has-text("Turn on logging")');
  if (enable) {
    await enable.click();
    record('logs: enable → toast', await waitToast(page, 'File logging on'));
    await page.waitForSelector('.log-list, .empty', { timeout: 6000 }).catch(() => {});
    record('logs: renders after enabling', !!(await page.$('.toolbar')));
  } else {
    record('logs: renders', !!(await page.$('.log-list, .empty')), 'logging already on');
  }

  // --- Models: provider filter + search
  await page.click('.rail .nav-link:has-text("Models")');
  await page.waitForTimeout(400);
  await page.fill('input[aria-label="Search models"]', 'zzz-no-such-model');
  record('models: search empty state', !!(await page.waitForSelector('text=No matching models', { timeout: 3000 }).catch(() => null)));
  await page.fill('input[aria-label="Search models"]', '');

  // --- Models: build a cross-provider fallback chain (provider → model → add)
  const chainSteps = () => page.locator('.chain-step').count();
  const stepsBefore = await chainSteps();
  const providerIds = await page.$$eval('#chain-provider option', (o) => o.map((x) => x.value));
  record('models: chain adder lists Kiro as a provider', providerIds.includes('kiro'), providerIds.join(','));
  if (providerIds.includes('kiro') && providerIds.includes('codex')) {
    await page.selectOption('#chain-provider', 'kiro');
    await page.selectOption('#chain-model', 'kiro/claude-opus-5.5');
    await page.click('button:has-text("Add to chain")');
    await page.waitForTimeout(800);
    await page.selectOption('#chain-provider', 'codex');
    await page.click('button:has-text("Add to chain")');
    await page.waitForTimeout(800);
    const steps = await page.$$eval('.chain-step .mono', (n) => n.map((x) => x.textContent));
    record('models: chain keeps Kiro then Codex in order', steps[stepsBefore] === 'kiro/claude-opus-5.5' && steps.length === stepsBefore + 2, steps.join(' → '));
    for (const id of steps.slice(stepsBefore)) {
      await page.click(`button[aria-label="Remove ${id} from the fallback chain"]`);
      await page.waitForTimeout(600);
    }
    record('models: chain steps can be removed', (await chainSteps()) === stepsBefore);
  }

  // --- Playground: provider first, then its models
  await page.click('.rail .nav-link:has-text("Playground")');
  await page.waitForTimeout(400);
  if (providerIds.includes('codex')) {
    await page.selectOption('#pg-provider', 'codex');
    const pgModels = await page.$$eval('#pg-model option', (o) => o.map((x) => x.value));
    record('playground: model list follows the provider', pgModels.length > 0 && pgModels.every((m) => !m.startsWith('kiro/')), pgModels.join(','));
  } else {
    record('playground: provider picker renders', !!(await page.$('#pg-provider')));
  }

  // --- Dark theme is pitch black
  await page.evaluate(() => localStorage.setItem('vr_theme', 'dark'));
  await page.reload({ waitUntil: 'networkidle' });
  const bg = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  record('dark: page background is pitch black', bg === 'rgb(0, 0, 0)', bg);

  // --- Overview: copy endpoint
  await page.click('.rail .nav-link:has-text("Overview")');
  await page.waitForTimeout(400);
  await page.click('button[aria-label="Copy Anthropic base URL"]');
  const clip = await page.evaluate(() => navigator.clipboard.readText()).catch(() => '');
  record('overview: copy base URL', /^https?:\/\/.+/.test(clip), clip);

  // --- Mobile widths: no horizontal scroll, drawer nav works
  for (const w of [320, 375, 414, 768]) {
    await page.setViewportSize({ width: w, height: 800 });
    for (const [path] of PAGES) {
      await page.goto(`${BASE}/management.html#/${path}`, { waitUntil: 'networkidle' });
      await page.waitForTimeout(250);
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
      if (overflow > 1) record(`mobile ${w}px: ${path} fits`, false, `${overflow}px overflow`);
    }
    record(`mobile ${w}px: no horizontal overflow`, true);
    if (w === 375) {
      await page.goto(`${BASE}/management.html#/overview`, { waitUntil: 'networkidle' });
      await page.screenshot({ path: join(SHOTS, 'mobile-overview.png'), fullPage: true });
      await page.click('button[aria-label="Open navigation"]');
      await page.waitForTimeout(450);
      await page.screenshot({ path: join(SHOTS, 'mobile-drawer.png') });
      await page.click('.rail .nav-link:has-text("Models")');
      await page.waitForURL('**#/models');
      await page.waitForTimeout(450);
      const closed = await page.evaluate(() => document.querySelector('.rail')?.getAttribute('data-open'));
      record('mobile: drawer navigates and closes', closed === 'false');
    }
  }

  // --- Error accounting
  const expected = [/^GET \/v0\/management\/logs(\?.*)? → 400$/, /→ 401$/];
  const unexpected = httpFailures.filter((f) => !expected.some((re) => re.test(f)));
  record('no unexpected HTTP failures', unexpected.length === 0, unexpected.slice(0, 5).join(' | ') || `clean (${httpFailures.length} expected)`);
  record('no uncaught page errors', pageErrors.length === 0, pageErrors.slice(0, 3).join(' | ') || 'clean');
  const realConsole = consoleErrors.filter((e) => !/Failed to load resource/.test(e));
  record('no unhandled console errors', realConsole.length === 0, realConsole.slice(0, 3).join(' | ') || 'clean');

  await browser.close();
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  if (failed.length) {
    console.log('FAILURES:');
    failed.forEach((f) => console.log(`  - ${f.name}: ${f.detail}`));
    process.exit(1);
  }
}

main().catch((err) => {
  console.error('UI test harness error:', err);
  process.exit(2);
});
