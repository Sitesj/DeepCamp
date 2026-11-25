/*
 * Deer Camp end-to-end tests (Playwright + Chromium, phone-sized viewport).
 *
 *   node tests/e2e/run.js            # all tests
 *   SCREENSHOTS=dir node tests/e2e/run.js
 *
 * Supabase is replaced by tests/e2e/fake-supabase.js (routed in the browser),
 * so these tests check the app's own behaviour: local saving, offline use,
 * sync/retry/idempotency, maps, replay and JSON round trips. They do NOT
 * prove a live Supabase project is configured correctly — see tests/db for
 * the database policy tests.
 */
const http = require('http');
const fs = require('fs');
const path = require('path');
let playwright;
try { playwright = require('playwright'); } catch (_) { playwright = require(path.join(require('child_process').execSync('npm root -g').toString().trim(), 'playwright')); }
const { FakeSupabase } = require('./fake-supabase');

const ROOT = path.resolve(__dirname, '../..');
const SUPA = 'https://fake-project.supabase.test';
const SHOTS = process.env.SCREENSHOTS || '';
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript', '.css': 'text/css', '.png': 'image/png', '.svg': 'image/svg+xml', '.json': 'application/json', '.webmanifest': 'application/manifest+json' };

function serve() {
  return new Promise((resolve) => {
    const srv = http.createServer((req, res) => {
      let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
      if (p.endsWith('/')) p += 'index.html';
      const f = path.join(ROOT, p);
      if (!f.startsWith(ROOT) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); res.end('not found'); return; }
      res.writeHead(200, { 'Content-Type': TYPES[path.extname(f)] || 'application/octet-stream', 'Cache-Control': 'no-cache' });
      fs.createReadStream(f).pipe(res);
    });
    srv.listen(0, '127.0.0.1', () => resolve(srv));
  });
}

// ------------------------------------------------------------------ harness
const results = [];
async function test(name, fn) {
  const t0 = Date.now();
  try { await fn(); results.push({ name, ok: true, ms: Date.now() - t0 }); console.log('  ✔ ' + name); }
  catch (e) { results.push({ name, ok: false, err: e }); console.log('  ✘ ' + name + '\n      ' + (e && e.stack || e).toString().split('\n').slice(0, 4).join('\n      ')); }
}
function assert(c, msg) { if (!c) throw new Error('Assertion failed: ' + msg); }
async function waitFor(fn, ms, label) {
  const end = Date.now() + (ms || 10000);
  let last;
  while (Date.now() < end) { try { last = await fn(); if (last) return last; } catch (e) { last = e; } await new Promise((r) => setTimeout(r, 100)); }
  throw new Error('Timed out waiting for ' + (label || 'condition') + (last instanceof Error ? ': ' + last.message : ''));
}
async function shot(page, name) { if (SHOTS) { fs.mkdirSync(SHOTS, { recursive: true }); await page.screenshot({ path: path.join(SHOTS, name + '.png') }); } }

// ------------------------------------------------------------------ app helpers
async function makeContext(browser, fake, opts) {
  opts = opts || {};
  const ctx = await browser.newContext({
    viewport: opts.viewport || { width: 375, height: 667 }, isMobile: true, hasTouch: true, deviceScaleFactor: 1,
    serviceWorkers: 'allow', acceptDownloads: true
  });
  if (fake) {
    await ctx.addInitScript((url) => { localStorage.setItem('deercamp-config', JSON.stringify({ supabaseUrl: url, supabaseKey: 'sb_publishable_test' })); }, SUPA);
    await ctx.route(SUPA + '/**', (route) => fake.handle(route));
  }
  // No real outside traffic: imagery fails (as with no service); weather is faked.
  await ctx.route(/arcgisonline\.com|openstreetmap\.org/, (r) => r.abort('internetdisconnected'));
  await ctx.route(/api\.open-meteo\.com/, (r) => {
    const now = Math.floor(Date.now() / 1000);
    const hours = Array.from({ length: 72 }, (_, i) => Math.floor(now / 3600) * 3600 - 24 * 3600 + i * 3600);
    r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({
      current: { time: now - 300, temperature_2m: 38.6, wind_speed_10m: 7.2, wind_direction_10m: 315, pressure_msl: 1018.2, precipitation: 0, weather_code: 2 },
      hourly: { time: hours, temperature_2m: hours.map(() => 37), wind_speed_10m: hours.map(() => 6), wind_direction_10m: hours.map(() => 300), pressure_msl: hours.map(() => 1017), precipitation: hours.map(() => 0), weather_code: hours.map(() => 3) }
    }) });
  });
  return ctx;
}
async function open(ctx, base) {
  const page = await ctx.newPage();
  page.on('pageerror', (e) => { console.log('      [pageerror] ' + e.message); page._errors = (page._errors || []).concat(e.message); });
  await page.goto(base + '/index.html');
  await page.waitForFunction(() => window.DeerCampApp);
  return page;
}
const CAMP_CODE = '482913';
const ADMIN_PIN = '135790';
/** Join the camp on this phone: type the camp code, tap the hunter's name (and the admin PIN for administrators). */
async function joinCamp(page, name, code, adminPin) {
  await page.waitForSelector('#screen-signin.active');
  await page.fill('#jnCode', code || CAMP_CODE);
  await page.click('#jnSubmit');
  await page.waitForSelector('#joinNameCard:not(.hidden)');
  await page.locator('#jnNames button', { hasText: name }).click();
  if (adminPin) {
    await page.waitForSelector('#joinPinCard:not(.hidden)');
    await page.fill('#jnPin', adminPin);
    await page.click('#jnPinSubmit');
  }
}
const btn = (page, text) => page.locator('button:visible', { hasText: text }).first();
async function chooseStand(page, name) {
  await page.waitForSelector('#screen-stand.active');
  await page.locator('#standList button', { hasText: name }).click();
  await page.waitForSelector('#screen-home.active');
}
async function recordDeer(page, o) {
  await page.click('#logDeerBtn');
  await page.waitForSelector('#wizard.open');
  await page.locator('#wzCompass .cpt[data-dir="' + o.first + '"]').click();
  await page.waitForSelector('text=How far away was the deer?');
  await page.locator('#wzBody button', { hasText: o.dist }).click();
  await page.waitForSelector('text=Which direction was the deer headed?');
  if (o.head) await page.locator('#wzCompass .cpt[data-dir="' + o.head + '"]').click();
  else await page.click('#wzNotSure');
  await page.waitForSelector('text=How many of each?');
  const counts = o.counts || { [o.type]: o.qty || 1 };
  for (const [t, n] of Object.entries(counts)) await page.selectOption('#wzBody select[data-type="' + t + '"]', String(n));
  await page.click('#qNext');
  await page.waitForSelector('#wzSave');
  await page.click('#wzSave');
  await page.waitForSelector('#confirm.open');
  const msg = await page.textContent('#cfMsg');
  await page.click('#cfOk');
  return msg;
}
async function recordGunshot(page, dir) {
  await page.click('#gunshotBtn');
  await page.waitForSelector('#gunshot.open');
  await page.locator('#gsCompass .cpt[data-dir="' + dir + '"]').click();
  await page.waitForSelector('#confirm.open');
  const msg = await page.textContent('#cfMsg');
  await page.click('#cfOk');
  return msg;
}
const local = (page, store) => page.evaluate((s) => window.DeerCampApp.DB.all(s), store);
const menu = async (page, go) => { await page.click('#menuBtn'); await page.click('#menu [data-go="' + go + '"]'); await page.waitForSelector('#screen-' + go + '.active'); };

// ------------------------------------------------------------------ tests
(async () => {
  const srv = await serve();
  const base = 'http://127.0.0.1:' + srv.address().port;
  const browser = await playwright.chromium.launch();
  const fake = new FakeSupabase(SUPA);
  const mikeId = fake.addHunter('Mike', { admin: true });
  const johnId = fake.addHunter('John');
  fake.addHunter('Dave');
  fake.campCode = CAMP_CODE;
  fake.adminPin = ADMIN_PIN;
  const ridge = fake.addStand('North Ridge', 38.5000, -90.5000);
  const creek = fake.addStand('Creek Stand', 38.5040, -90.4930);
  fake.addStand('South Woods', 38.4965, -90.4975);

  console.log('Deer Camp end-to-end tests (' + base + ')');
  const mikeCtx = await makeContext(browser, fake);
  let page = await open(mikeCtx, base);

  await test('A: sign in, select stand, start hunt, record deer sighting, saved locally and synced', async () => {
    await shot(page, '01-signin');
    // a wrong code is refused
    await page.waitForSelector('#screen-signin.active');
    await page.fill('#jnCode', '111111');
    await page.click('#jnSubmit');
    await waitFor(async () => (await page.textContent('#jnError')).includes('not right'), 5000, 'wrong code message');
    // Mike is an administrator: the camp code alone is not enough
    await page.fill('#jnCode', CAMP_CODE);
    await page.click('#jnSubmit');
    await page.waitForSelector('#joinNameCard:not(.hidden)');
    assert((await page.textContent('#jnNames')).includes('needs the admin PIN'), 'admin name is marked');
    await page.locator('#jnNames button', { hasText: 'Mike' }).click();
    await page.waitForSelector('#joinPinCard:not(.hidden)');
    await shot(page, '01c-admin-pin');
    await page.fill('#jnPin', '000000');
    await page.click('#jnPinSubmit');
    await waitFor(async () => (await page.textContent('#jnPinError')).includes('not right'), 5000, 'wrong admin PIN message');
    assert(!fake.devices.size, 'not joined with a wrong admin PIN');
    await page.fill('#jnPin', CAMP_CODE);
    await page.click('#jnPinSubmit');
    await waitFor(async () => (await page.textContent('#jnPinError')).includes('not right'), 5000, 'camp code is not the admin PIN');
    await page.fill('#jnPin', ADMIN_PIN);
    await page.click('#jnPinSubmit');
    await chooseStand(page, 'North Ridge');
    await shot(page, '02-home');
    assert((await page.textContent('#homeHunter')) === 'Mike', 'hunter name shown');
    await page.click('#huntToggle');
    await waitFor(() => page.evaluate(() => !!window.DeerCampApp.S.session), 5000, 'session');
    // weather is attached from the phone's cache (it never delays recording), so let it arrive first
    await waitFor(() => page.evaluate(() => window.DeerCampApp.DB.all('weather').then((w) => w.length > 0)), 5000, 'weather cached');
    const before = Date.now();
    const msg = await recordDeer(page, { first: 'NE', dist: '50–75', head: 'SW', qty: 2, type: 'doe' });
    assert(msg === 'SIGHTING SAVED', 'confirmation: ' + msg);
    const recs = await local(page, 'sightings');
    assert(recs.length === 1, 'one local sighting');
    const r = recs[0];
    assert(r.first_seen_direction === 'NE' && r.first_seen_bearing === 45, 'first seen');
    assert(r.heading_direction === 'SW' && r.heading_bearing === 225, 'heading');
    assert(r.distance_range === '50-75' && r.quantity === 2 && r.deer_type === 'doe', 'details');
    assert(r.hunter_id === mikeId && r.stand_id === ridge.id && r.stand_latitude === 38.5, 'stand/hunter');
    assert(Date.parse(r.observed_at) <= before + 2000 && Date.parse(r.observed_at) >= before - 60000, 'observed_at captured at start');
    assert(r.weather && r.weather.source === 'open-meteo' && r.weather.temperature_f === 38.6, 'weather attached');
    await waitFor(() => fake.tables.deer_sightings.length === 1 && fake.tables.hunting_sessions.length === 1, 10000, 'upload');
    const srvRec = fake.tables.deer_sightings[0];
    assert(srvRec.id === r.id && srvRec.observed_at === r.observed_at, 'server has same id + original timestamp');
    await waitFor(async () => (await local(page, 'sightings'))[0]._sync === 'synced', 5000, 'marked synced');
    await waitFor(async () => (await page.textContent('#syncStatus')).includes('Synced'), 5000, 'status Synced');
    assert((await page.textContent('#cntDeer')) === '1', 'today count');
  });

  await test('D: gunshot report saved with stand, timestamp and bearing', async () => {
    const t0 = Date.now();
    await page.click('#gunshotBtn');
    await page.waitForSelector('#gunshot.open');
    await shot(page, '05-gunshot-compass');
    await page.waitForTimeout(400);
    await page.locator('#gsCompass .cpt[data-dir="NW"]').click();
    await page.waitForSelector('#confirm.open');
    await page.click('#cfOk');
    const g = (await local(page, 'gunshots'))[0];
    assert(g.direction === 'NW' && g.bearing === 315, 'bearing 315');
    assert(g.stand_id === ridge.id && g.stand_latitude === ridge.latitude, 'stand');
    assert(Date.parse(g.observed_at) >= t0 - 1000 && Date.parse(g.observed_at) <= t0 + 2000, 'timestamp captured at tap');
    await waitFor(() => fake.tables.gunshot_reports.some((x) => x.id === g.id && x.bearing === 315), 10000, 'gunshot uploaded');
  });

  await test('Mixed group: 3 does, 1 buck and 2 fawns in one sighting', async () => {
    await page.click('#logDeerBtn');
    await page.waitForSelector('#wizard.open');
    await page.locator('#wzCompass .cpt[data-dir="ESE"]').click();
    await page.locator('#wzBody button', { hasText: '25–50' }).click();
    await page.locator('#wzCompass .cpt[data-dir="N"]').click();
    await page.waitForSelector('text=How many of each?');
    assert(await page.isDisabled('#qNext'), 'NEXT disabled until a deer is chosen');
    const sel = await page.locator('#wzBody select[data-type]').evaluateAll((els) => els.map((e) => { const r = e.getBoundingClientRect(); return { t: e.dataset.type, h: r.height, w: r.width }; }));
    assert(sel.map((x) => x.t).join() === 'buck,doe,fawn,unknown', 'a dropdown for each type: ' + sel.map((x) => x.t));
    assert(sel.every((x) => x.h >= 56 && x.w >= 90), 'dropdowns are large');
    await page.selectOption('#wzBody select[data-type="doe"]', '3');
    await page.selectOption('#wzBody select[data-type="buck"]', '1');
    await page.selectOption('#wzBody select[data-type="fawn"]', '2');
    assert((await page.textContent('#cTotal')).includes('Total: 6 deer'), 'running total');
    await shot(page, '04b-counts');
    await page.click('#qNext');
    await page.waitForSelector('#wzSave');
    assert((await page.textContent('#wzBody')).includes('1 Buck, 3 Does, 2 Fawns'), 'summary shows the group');
    await page.click('#wzSave');
    await page.waitForSelector('#confirm.open');
    await page.click('#cfOk');
    const r = (await local(page, 'sightings')).find((x) => x.first_seen_direction === 'ESE');
    assert(r.quantity === 6 && r.deer_type === 'mixed' && r.buck_count === 1 && r.doe_count === 3 && r.fawn_count === 2 && r.unknown_count === 0, 'counts saved');
    await waitFor(() => fake.tables.deer_sightings.some((x) => x.id === r.id && x.fawn_count === 2 && x.deer_type === 'mixed'), 10000, 'mixed group uploaded');
  });

  await test('H: compass on narrow phones — 16 clickable circles, no duplicate buttons, large targets', async () => {
    for (const vp of [{ width: 320, height: 568 }, { width: 360, height: 740 }, { width: 414, height: 896 }]) {
      await page.setViewportSize(vp);
      await page.click('#logDeerBtn');
      await page.waitForSelector('#wizard.open');
      const info = await page.evaluate(() => {
        const pts = Array.from(document.querySelectorAll('#wzCompass .cpt')).map((b) => { const r = b.getBoundingClientRect(); return { d: b.dataset.dir, x: r.x, y: r.y, w: r.width, h: r.height, round: getComputedStyle(b).borderRadius }; });
        const dirs = window.DeerCore.DIRECTIONS;
        const allButtons = Array.from(document.querySelectorAll('#wizard button')).filter((b) => b.offsetParent);
        const dirButtons = allButtons.filter((b) => dirs.includes(b.textContent.trim()));
        const selects = document.querySelectorAll('#wizard select').length;
        return { pts, dirButtons: dirButtons.length, selects, vw: innerWidth, vh: innerHeight };
      });
      assert(info.pts.length === 16, '16 markers');
      assert(info.dirButtons === 16, 'exactly 16 direction buttons (no duplicates) at ' + vp.width);
      assert(info.selects === 0, 'no dropdown');
      info.pts.forEach((p) => {
        assert(p.x >= 0 && p.y >= 0 && p.x + p.w <= info.vw, p.d + ' visible at ' + vp.width);
        assert(p.w >= 44 && p.h >= 44, p.d + ' is ' + Math.round(p.w) + 'px at ' + vp.width);
        assert(p.round === '50%', p.d + ' is circular');
      });
      for (let i = 0; i < 16; i++) for (let j = i + 1; j < 16; j++) {
        const a = info.pts[i], b = info.pts[j];
        const d = Math.hypot(a.x - b.x, a.y - b.y);
        assert(d >= a.w * 0.95, 'markers ' + a.d + '/' + b.d + ' do not overlap at ' + vp.width);
      }
      const n = info.pts.find((p) => p.d === 'N'), s = info.pts.find((p) => p.d === 'S');
      assert(n.y < s.y && Math.abs(n.x - s.x) < 1, 'north at top');
      if (vp.width === 320) await shot(page, '03-compass-320');
      if (vp.width === 360) await shot(page, '03-compass-360');
      // the marker itself advances the workflow
      await page.locator('#wzCompass .cpt[data-dir="E"]').click();
      await page.waitForSelector('text=How far away was the deer?');
      if (vp.width === 360) await shot(page, '04-distance');
      await page.click('#wzCancel');
      const dlg = page.locator('#dialogBox button[data-v="1"]');
      if (await dlg.count()) await dlg.click();
      await page.waitForSelector('#wizard:not(.open)', { state: 'attached' });
    }
    await page.setViewportSize({ width: 375, height: 667 });
  });

  await test('B + I: offline recording survives closing and reopening the app with no connection', async () => {
    await page.waitForFunction(() => navigator.serviceWorker.controller, null, { timeout: 15000 });
    await mikeCtx.setOffline(true);
    await page.evaluate(() => window.dispatchEvent(new Event('offline')));
    const msg = await recordDeer(page, { first: 'W', dist: '100–200', head: null, qty: 1, type: 'buck' });
    assert(msg === 'SAVED ON PHONE — WILL SYNC LATER', 'offline confirmation: ' + msg);
    await waitFor(async () => (await page.textContent('#syncStatus')).includes('Waiting to Sync'), 3000, 'waiting status');
    await shot(page, '06-offline-home');
    await page.close();
    page = await open(mikeCtx, base); // reopened while offline: served by the service worker
    await page.waitForSelector('#screen-home.active');
    const recs = await local(page, 'sightings');
    const off = recs.find((r) => r.first_seen_direction === 'W');
    assert(off && off._sync === 'pending' && off.heading_direction === null && off.heading_bearing === null, 'offline record kept, NOT SURE heading stored as null');
    assert(!fake.tables.deer_sightings.some((x) => x.id === off.id), 'not on server yet');
    assert((await page.textContent('#netStatus')).includes('Offline'), 'shows offline');
    await menu(page, 'activity');
    await waitFor(async () => (await page.textContent('#actList')).includes('1 Buck'), 5000, 'feed render');
    const feed = await page.textContent('#actList');
    assert(feed.includes('Waiting to Sync') && feed.includes('1 Buck'), 'feed shows pending: ' + feed);
    assert(await page.isVisible('#actOffline'), 'offline note in feed');
    await shot(page, '07-activity-offline');
    await menu(page, 'home');
  });

  await test('C: reconnection syncs multiple offline records without duplicates (incl. lost server reply)', async () => {
    await recordDeer(page, { first: 'S', dist: '0–25', head: 'E', qty: 3, type: 'unknown' });
    await recordGunshot(page, 'SSE');
    const pending = (await local(page, 'outbox')).length;
    assert(pending === 3, 'three queued, got ' + pending);
    const before = fake.tables.deer_sightings.length;
    fake.dropNextUpsertResponse = 1; // the first upload is saved by the server but the reply is lost
    await mikeCtx.setOffline(false);
    await page.evaluate(() => window.dispatchEvent(new Event('online')));
    await waitFor(async () => (await local(page, 'outbox')).length === 0 || (await page.textContent('#syncStatus')).includes('Failed'), 15000, 'first sync pass');
    // retry (manual tap) until everything is confirmed
    await waitFor(async () => {
      if ((await local(page, 'outbox')).length === 0) return true;
      await page.click('#syncStatus');
      return false;
    }, 15000, 'retry');
    assert(fake.tables.deer_sightings.length === before + 2, 'exactly two new sightings on server, got ' + (fake.tables.deer_sightings.length - before));
    const ids = fake.tables.deer_sightings.map((r) => r.id);
    assert(new Set(ids).size === ids.length, 'no duplicate ids');
    assert(fake.tables.gunshot_reports.length === 2, 'two gunshots on server');
    const all = (await local(page, 'sightings')).concat(await local(page, 'gunshots'));
    assert(all.every((r) => r._sync === 'synced'), 'all marked synced');
    const offRec = all.find((r) => r.first_seen_direction === 'W');
    assert(fake.tables.deer_sightings.find((x) => x.id === offRec.id).observed_at === offRec.observed_at, 'original time preserved');
  });

  await test('Correction: voiding keeps the original record (audit) and syncs the void', async () => {
    await recordGunshot(page, 'N');
    const g = (await local(page, 'gunshots')).find((x) => x.direction === 'N');
    await waitFor(() => fake.tables.gunshot_reports.some((x) => x.id === g.id), 8000, 'upload');
    await page.click('#lastRecUndo');
    await page.locator('#dialogBox button', { hasText: 'VOID IT' }).click();
    await waitFor(() => { const s = fake.tables.gunshot_reports.find((x) => x.id === g.id); return s && s.status === 'voided'; }, 8000, 'void synced');
    const l = (await local(page, 'gunshots')).find((x) => x.id === g.id);
    assert(l && l.status === 'voided' && l.direction === 'N', 'local record kept as voided');
  });

  const johnCtx = await makeContext(browser, fake);
  let jpage = await open(johnCtx, base);
  await test('E: two hunters at different stands; both see shared records', async () => {
    await jpage.waitForSelector('#screen-signin.active');
    await jpage.fill('#jnCode', CAMP_CODE);
    await jpage.click('#jnSubmit');
    await jpage.waitForSelector('#joinNameCard:not(.hidden)');
    // Mike's name is locked to Mike's phone
    assert(await jpage.locator('#jnNames button', { hasText: 'Mike' }).isDisabled(), "Mike's name cannot be picked on John's phone");
    assert((await jpage.textContent('#jnNames')).includes('In use on another phone'), 'shows why');
    await shot(jpage, '01b-pick-name');
    await jpage.locator('#jnNames button', { hasText: 'John' }).click();
    await chooseStand(jpage, 'Creek Stand');
    await recordGunshot(jpage, 'NW');
    await recordDeer(jpage, { first: 'E', dist: '25–50', head: 'N', qty: 1, type: 'buck' });
    await waitFor(() => fake.tables.deer_sightings.some((x) => x.hunter_id === johnId), 10000, 'john uploaded');
    await page.click('#syncStatus');
    await menu(page, 'activity');
    await waitFor(async () => (await page.textContent('#actList')).includes('John'), 10000, "John's record in Mike's feed");
    const feed = await page.textContent('#actList');
    assert(feed.includes('Creek Stand') && feed.includes('North Ridge') && feed.includes('Mike'), 'both hunters/stands');
    await shot(page, '08-activity');
    await menu(jpage, 'activity');
    await waitFor(async () => (await jpage.textContent('#actList')).includes('Mike'), 10000, "Mike's record in John's feed");
  });

  await test('E2: records are never reassigned to another hunter on a shared phone', async () => {
    await jpage.evaluate(() => window.dispatchEvent(new Event('offline')));
    await johnCtx.setOffline(true);
    await menu(jpage, 'home');
    await recordGunshot(jpage, 'E');
    const held = (await local(jpage, 'gunshots')).find((x) => x.direction === 'E');
    await johnCtx.setOffline(false);
    await menu(jpage, 'settings');
    // John hands the phone to Dave without syncing first
    fake.down = true;
    await jpage.click('#setSwitch');
    await jpage.locator('#dialogBox button[data-v="1"]').click();
    fake.down = false;
    await joinCamp(jpage, 'Dave');
    await jpage.waitForSelector('#screen-home.active, #screen-stand.active');
    await jpage.waitForTimeout(1500);
    assert(!fake.tables.gunshot_reports.some((x) => x.id === held.id), "John's record NOT uploaded under Dave");
    const ob = await local(jpage, 'outbox');
    assert(ob.some((o) => o.record_id === held.id && o.hunter_id === johnId), 'still queued for John');
    // back to John: it uploads
    await menu(jpage, 'settings');
    await jpage.click('#setSwitch');
    await jpage.locator('#dialogBox button[data-v="1"]').click();
    await joinCamp(jpage, 'John');
    await waitFor(() => fake.tables.gunshot_reports.some((x) => x.id === held.id && x.hunter_id === johnId), 10000, 'uploaded as John');
  });

  await test('Live map and heat map show stands and estimated deer locations', async () => {
    await menu(page, 'map');
    await page.waitForSelector('#liveMap .stand-pin');
    await page.click('#syncStatus');
    await waitFor(async () => (await page.locator('#liveMap .deer-pin').count()) >= 4, 10000, 'deer pins');
    const names = await page.locator('#liveMap .stand-pin .nm').allTextContents();
    assert(['North Ridge', 'Creek Stand', 'South Woods'].every((n) => names.includes(n)), 'all stands on one map: ' + names);
    assert((await page.locator('#liveMap path[stroke-dasharray]').count()) >= 1, 'dashed gunshot direction lines');
    await shot(page, '09-live-map');
    await menu(page, 'heat');
    await page.waitForSelector('#heatMap canvas.leaflet-heatmap-layer');
    assert((await page.textContent('#hmCount')).includes('sighting report'), 'heat count');
    await shot(page, '10-heat-map');
  });

  await test('F: hunt replay — chronological, positions, arrows, red !, dashed arrows, BANG!', async () => {
    await menu(page, 'replay');
    await page.waitForSelector('#rpList .rp-ev');
    const list = await page.locator('#rpList .rp-ev').allTextContents();
    assert(list.length >= 7, 'events listed: ' + list.length);
    const times = await page.evaluate(() => window.DeerCampApp.Replay.events.map((e) => e.t));
    for (let i = 1; i < times.length; i++) assert(times[i] >= times[i - 1], 'chronological');
    assert(list.some((t) => t.includes('Creek Stand')) && list.some((t) => t.includes('North Ridge')), 'all stands on one timeline');
    await page.click('#rpRestart');
    assert((await page.locator('#replayMap .deer-pin').count()) === 0, 'nothing shown before first event');
    await page.selectOption('#rpSpeed', '300');
    await page.click('#rpPlay');
    await page.waitForSelector('#replayMap .bang', { timeout: 15000 });
    await page.waitForTimeout(150);
    await shot(page, '11-replay-bang');
    await waitFor(() => page.evaluate(() => !window.DeerCampApp.Replay.playing), 20000, 'replay end');
    const geo = await page.evaluate(() => {
      const R = window.DeerCampApp.Replay, C = window.DeerCore;
      const out = { deer: [], guns: [] };
      const size = R.map.getSize();
      R.shown.forEach((v) => {
        if (v.kind === 'deer') {
          const ll = v.marker.getLatLng(), rec = R.events.find((e) => e.rec.id === [...R.shown.entries()].find(([, x]) => x === v)[0]).rec;
          out.deer.push({ dir: rec.first_seen_direction, bearing: C.initialBearing(rec.stand_latitude, rec.stand_longitude, ll.lat, ll.lng), dist: C.distanceMeters(rec.stand_latitude, rec.stand_longitude, ll.lat, ll.lng), range: rec.distance_range, arrows: v.layers.length });
        } else {
          const p = R.map.latLngToContainerPoint(v.end), s = R.map.latLngToContainerPoint([v.rec.stand_latitude, v.rec.stand_longitude]);
          out.guns.push({ edge: Math.min(p.x, p.y, size.x - p.x, size.y - p.y), bearing: (Math.atan2(p.x - s.x, -(p.y - s.y)) * 180 / Math.PI + 360) % 360, want: v.rec.bearing, alert: !!v.alert.getElement() });
        }
      });
      return out;
    });
    assert(geo.deer.length >= 4, 'deer shown at end: ' + geo.deer.length);
    geo.deer.forEach((d) => {
      assert(Math.abs(((d.bearing - window_bearing(d.dir)) + 540) % 360 - 180) < 0.5, d.dir + ' deer placed at bearing ' + d.bearing);
      assert(Math.abs(d.dist - mid(d.range) * 0.9144) < 0.5, 'deer at midpoint distance');
    });
    const ne = geo.deer.find((d) => d.dir === 'NE');
    assert(ne && ne.arrows === 2, 'NE deer has a travel arrow');
    const w = geo.deer.find((d) => d.dir === 'W');
    assert(w && w.arrows === 1, 'NOT SURE heading has no arrow');
    assert(geo.guns.length >= 3, 'gunshots shown');
    geo.guns.forEach((g) => {
      assert(g.alert, 'red exclamation shown');
      assert(Math.abs(((g.bearing - g.want) + 540) % 360 - 180) < 2, 'gunshot arrow points ' + g.want + ' (got ' + g.bearing.toFixed(1) + ')');
    });
    assert(geo.guns.some((g) => g.edge < 60), 'arrow extends to the visible map edge');
    assert((await page.locator('#replayMap .gun-alert').count()) >= 3, '! markers in DOM');
    await page.waitForTimeout(3000);
    assert((await page.locator('#replayMap .bang').count()) >= 1, 'BANG! still shown a few seconds later');
    const showMs = await page.evaluate(() => window.DeerCampApp.Replay.GUN_SHOW_MS);
    assert(showMs === 30000, 'gunshots stay 30 seconds (real time)');
    await shot(page, '12-replay-end');
    // Gunshot !, arrows and BANG! disappear after their time; deer stay. (Shortened to 1.5 s for the test.)
    await page.evaluate(() => { window.DeerCampApp.Replay.GUN_SHOW_MS = 1500; });
    await page.click('#rpRestart');
    await page.click('#rpPlay');
    await waitFor(() => page.evaluate(() => !window.DeerCampApp.Replay.playing), 20000, 'replay end');
    await waitFor(async () => (await page.locator('#replayMap .bang').count()) === 0 &&
      (await page.locator('#replayMap .gun-alert').count()) === 0 &&
      (await page.locator('#replayMap path[stroke-dasharray]').count()) === 0, 4000, 'gunshot visuals removed after their time');
    assert((await page.locator('#replayMap .deer-pin').count()) >= 4, 'deer remain on the map');
    const listed = await page.locator('#rpList .rp-ev.gun').count();
    assert(listed >= 3, 'gunshots still listed in the event list');
    await page.evaluate(() => { window.DeerCampApp.Replay.GUN_SHOW_MS = 30000; });
    // scrubbing back hides later events
    await page.click('#rpRestart');
    assert((await page.locator('#replayMap .deer-pin').count()) === 0, 'restart clears map');
    function window_bearing(d) { return ['N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW'].indexOf(d) * 22.5; }
    function mid(k) { return { '0-25': 12.5, '25-50': 37.5, '50-75': 62.5, '75-100': 87.5, '100-200': 150 }[k]; }
  });

  await test('G: export JSON, import into separate replay dataset, unchanged and not duplicated', async () => {
    await menu(page, 'settings');
    await page.locator('#exScope .chip[data-s="all"]').click();
    const [dl] = await Promise.all([page.waitForEvent('download'), page.click('#exBtn')]);
    const file = await dl.path();
    const exp = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert(exp.schema === 'deer-camp-hunt-export' && exp.schema_version === 2, 'schema');
    assert(!/propert/i.test(JSON.stringify(exp)), 'no property info');
    const localS = await local(page, 'sightings');
    assert(exp.deer_sightings.length === localS.length, 'all sightings exported');
    exp.deer_sightings.forEach((e) => {
      const l = localS.find((x) => x.id === e.id);
      assert(l && l.observed_at === e.observed_at && l.first_seen_bearing === e.first_seen_bearing && l.heading_bearing === e.heading_bearing && l.quantity === e.quantity, 'record unchanged ' + e.id);
    });
    assert(exp.stands.every((s) => typeof s.latitude === 'number' && s.name), 'stand coordinates');
    assert(exp.hunters.some((h) => h.display_name === 'John'), 'hunter names');
    if (SHOTS) fs.copyFileSync(file, path.join(SHOTS, 'export.json'));
    const serverBefore = fake.writes.length;
    await page.setInputFiles('#imFile', { name: 'hunt.json', mimeType: 'application/json', buffer: fs.readFileSync(file) });
    await waitFor(async () => (await page.textContent('#imInfo')).includes('Imported'), 5000, 'import');
    const n = exp.deer_sightings.length + exp.gunshot_reports.length;
    assert((await page.textContent('#imInfo')).includes(n + ' new event'), 'events imported: ' + await page.textContent('#imInfo'));
    await page.setInputFiles('#imFile', { name: 'hunt.json', mimeType: 'application/json', buffer: fs.readFileSync(file) });
    await waitFor(async () => (await page.textContent('#imInfo')).includes('already imported'), 5000, 'second import');
    assert((await page.textContent('#imInfo')).includes('0 new event'), 'no duplicates on re-import');
    const imp = await local(page, 'imports');
    assert(imp.filter((r) => r.kind === 'sightings').length === exp.deer_sightings.length, 'import store has no duplicates');
    assert(fake.writes.length === serverBefore, 'import uploaded nothing');
    // bad file is rejected
    await page.setInputFiles('#imFile', { name: 'bad.json', mimeType: 'application/json', buffer: Buffer.from('{"hello":1}') });
    await waitFor(async () => (await page.textContent('#imInfo')).includes('Not imported'), 5000, 'reject');
    // replay the imported data while offline
    await mikeCtx.setOffline(true);
    await menu(page, 'replay');
    await page.selectOption('#rpSource', 'import');
    await page.waitForSelector('#rpList .rp-ev');
    const evs = await page.evaluate(() => window.DeerCampApp.Replay.events.map((e) => e.rec.id));
    const want = exp.deer_sightings.concat(exp.gunshot_reports).filter((r) => r.status !== 'voided').map((r) => r.id);
    assert(want.every((id) => evs.includes(id)), 'imported events replay');
    await mikeCtx.setOffline(false);
  });

  await test('Camp code: wrong codes lock out; admin adds a hunter, releases a phone, changes the code', async () => {
    const ctx = await makeContext(browser, fake);
    const p = await open(ctx, base);
    await p.waitForSelector('#screen-signin.active');
    for (let i = 0; i < 5; i++) {
      await p.fill('#jnCode', '00000' + i);
      await p.click('#jnSubmit');
      await waitFor(async () => (await p.textContent('#jnError')).length > 0, 5000, 'error ' + i);
      if (i < 4) await p.evaluate(() => { document.getElementById('jnError').textContent = ''; });
    }
    await p.fill('#jnCode', CAMP_CODE);
    await p.click('#jnSubmit');
    await waitFor(async () => (await p.textContent('#jnError')).includes('Too many wrong tries'), 5000, 'lock-out message');
    assert(!(await p.isVisible('#screen-home')), 'no access');
    // Admin (Mike) adds "Earl", releases John's phone, changes the code
    await menu(page, 'settings');
    await page.waitForSelector('#setHuntersCard:not(.hidden)');
    await page.fill('#addHunterName', 'Earl');
    await page.click('#addHunterBtn');
    await waitFor(async () => (await page.textContent('#setHunterList')).includes('Earl'), 5000, 'Earl listed');
    await shot(page, '13-admin-hunters');
    await page.locator('#setHunterList .feed-item', { hasText: 'John' }).locator('button[data-h="release"]').click();
    await page.locator('#dialogBox button[data-v="1"]').click();
    await waitFor(() => ![...fake.devices.values()].includes(johnId), 5000, 'John released');
    await page.fill('#newCampCode', '777888');
    await page.click('#setCampCodeBtn');
    await page.locator('#dialogBox button[data-v="1"]').click();
    await waitFor(() => fake.campCode === '777888', 5000, 'code changed');
    await page.fill('#newAdminPin', '246802');
    await page.click('#setAdminPinBtn');
    await page.locator('#dialogBox button[data-v="1"]').click();
    await waitFor(() => fake.adminPin === '246802', 5000, 'admin PIN changed');
    // the new code works (lock-out was cleared), and Earl can join
    await p.evaluate(() => { document.getElementById('jnError').textContent = ''; });
    await joinCamp(p, 'Earl', '777888');
    await p.waitForSelector('#screen-stand.active, #screen-home.active');
    // John's released phone asks to join again; his records are kept
    await jpage.click('#syncStatus');
    await waitFor(async () => (await jpage.textContent('#syncStatus')).includes('Join again'), 8000, 'John asked to rejoin');
    await ctx.close();
  });

  await test('Camp sign-in turned off in Supabase gives a clear message', async () => {
    fake.anonymousEnabled = false;
    const ctx = await makeContext(browser, fake);
    const p = await open(ctx, base);
    await p.waitForSelector('#screen-signin.active');
    await p.fill('#jnCode', '777888');
    await p.click('#jnSubmit');
    await waitFor(async () => (await p.textContent('#jnError')).includes('Allow anonymous sign-ins'), 5000, 'setup hint');
    fake.anonymousEnabled = true;
    await ctx.close();
  });

  await test('Phone-only mode (no Supabase configured): pick hunter, add stand, record offline', async () => {
    const ctx = await makeContext(browser, null);
    const p = await open(ctx, base);
    await p.waitForSelector('#screen-hunter.active');
    await p.fill('#newLocalHunter', 'Dave');
    await p.click('#addLocalHunter');
    await p.locator('#localHunterList button', { hasText: 'Dave' }).click();
    await p.waitForSelector('#screen-stand.active');
    await p.click('#goAddStand');
    await p.fill('#dlgForm input[name="name"]', 'South Woods');
    await p.fill('#dlgForm input[name="lat"]', '38.4965, -90.4975');
    await p.click('#dlgOk');
    await waitFor(async () => (await p.textContent('#setStandList')).includes('South Woods'), 5000, 'stand saved');
    await p.click('#menuBtn'); await p.click('#menu [data-go="home"]'); // no stand yet => stand picker
    await p.waitForSelector('#screen-stand.active');
    await chooseStand(p, 'South Woods');
    const msg = await recordDeer(p, { first: 'E', dist: '75–100', head: 'N', qty: 1, type: 'buck' });
    assert(msg === 'SIGHTING SAVED ON PHONE', msg);
    assert((await p.textContent('#syncStatus')).includes('Saved on Phone'), 'status');
    assert((await local(p, 'outbox')).length === 0, 'nothing queued for upload');
    await ctx.close();
  });

  const errs = (page._errors || []).concat(jpage._errors || []);
  await test('No uncaught page errors', async () => { assert(errs.length === 0, errs.join('; ')); });

  await browser.close();
  srv.close();
  const failed = results.filter((r) => !r.ok);
  console.log('\n' + (results.length - failed.length) + ' passed, ' + failed.length + ' failed');
  process.exit(failed.length ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
