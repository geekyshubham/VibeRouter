/* Read-only smoke test against the LIVE installed instance (:8318).
   NO mutations — just load, log in if needed, visit every page in both
   themes, assert render + no crash. Safe to run against real user data. */
import { chromium } from 'playwright';

const BASE = process.argv[3] || 'http://127.0.0.1:8318';
const KEY = process.argv[2] || '';
const out = [];
const rec = (n, ok, d = '') => {
  out.push({ n, ok });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${n}${d ? ' — ' + d : ''}`);
};

const pageErrors = [];
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1360, height: 900 } });
page.on('pageerror', (e) => pageErrors.push(String(e)));

await page.goto(`${BASE}/management.html`, { waitUntil: 'networkidle', timeout: 15000 });
rec('live page loads', true, await page.title());
await page.waitForSelector('.gate-card, .app', { timeout: 8000 });
if (await page.$('#mgmt-key')) {
  await page.fill('#mgmt-key', KEY);
  await page.click('button:has-text("Unlock console")');
}
await page.waitForSelector('.app', { timeout: 8000 });
rec('live console reached', true);

for (const theme of ['dark', 'light']) {
  await page.evaluate((t) => localStorage.setItem('vr_theme', t), theme);
  await page.reload({ waitUntil: 'networkidle' });
  await page.waitForSelector('.app');
  for (const label of ['Overview', 'Playground', 'Accounts', 'Models', 'API keys', 'Logs', 'Settings']) {
    const before = pageErrors.length;
    await page.click(`.rail .nav-link:has-text("${label}")`);
    await page.waitForTimeout(600);
    rec(`live ${theme}: ${label}`, !!(await page.$('.view')) && pageErrors.length === before);
  }
}
rec('live: no uncaught page errors', pageErrors.length === 0, pageErrors.slice(0, 3).join(' | ') || 'clean');

await browser.close();
const failed = out.filter((r) => !r.ok);
console.log(`\n${out.length - failed.length}/${out.length} live checks passed`);
process.exit(failed.length ? 1 : 0);
