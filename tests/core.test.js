// Unit tests for js/core.js — run with: node --test tests/
const test = require('node:test');
const assert = require('node:assert/strict');
const C = require('../js/core.js');

const STAND = { id: '11111111-1111-4111-8111-111111111111', name: 'North Ridge', latitude: 38.5, longitude: -90.5 };
const HUNTER = '00000000-0000-4000-8000-00000000000b';
const SESSION = '33333333-3333-4333-8333-333333333333';

test('16 compass points, clockwise from north in 22.5° steps', () => {
  assert.deepEqual(C.DIRECTIONS, ['N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW']);
  assert.equal(C.bearingFor('N'), 0);
  assert.equal(C.bearingFor('NE'), 45);
  assert.equal(C.bearingFor('ESE'), 112.5);
  assert.equal(C.bearingFor('SW'), 225);
  assert.equal(C.bearingFor('NNW'), 337.5);
  assert.equal(C.bearingFor('XYZ'), null);
  C.DIRECTIONS.forEach((d) => assert.equal(C.directionFor(C.bearingFor(d)), d));
  assert.equal(C.directionFor(359), 'N');
  assert.equal(C.directionFor(-45), 'NW');
});

test('distance ranges and midpoints', () => {
  assert.deepEqual(C.DISTANCE_RANGES.map((r) => r.label), ['0–25 yards', '25–50 yards', '50–75 yards', '75–100 yards', '100–200 yards']);
  assert.equal(C.midpointYards('50-75'), 62.5);
  assert.equal(C.midpointYards('100-200'), 150);
  assert.equal(C.midpointYards('bogus'), null);
});

test('destination point matches known geodesic values', () => {
  // 1 degree of latitude ≈ 111.195 km on the mean-radius sphere
  const p = C.destinationPoint(0, 0, 0, 111195.08);
  assert.ok(Math.abs(p.lat - 1) < 1e-4);
  assert.ok(Math.abs(p.lng) < 1e-9);
  const e = C.destinationPoint(0, 0, 90, 111195.08);
  assert.ok(Math.abs(e.lng - 1) < 1e-4 && Math.abs(e.lat) < 1e-9);
  // round trip: distance and bearing back to the computed point
  const q = C.destinationPoint(38.5, -90.5, 222, 1234);
  assert.ok(Math.abs(C.distanceMeters(38.5, -90.5, q.lat, q.lng) - 1234) < 0.01);
  assert.ok(Math.abs(C.initialBearing(38.5, -90.5, q.lat, q.lng) - 222) < 0.01);
});

test('example: deer first seen NE at 50–75 yards is ~62.5 yd northeast of the stand', () => {
  const est = C.estimateSightingLocation(STAND.latitude, STAND.longitude, C.bearingFor('NE'), '50-75');
  const d = C.distanceMeters(STAND.latitude, STAND.longitude, est.lat, est.lng);
  assert.ok(Math.abs(d - 62.5 * 0.9144) < 0.01, 'distance ' + d);
  const b = C.initialBearing(STAND.latitude, STAND.longitude, est.lat, est.lng);
  assert.ok(Math.abs(b - 45) < 0.01, 'bearing ' + b);
  assert.ok(est.lat > STAND.latitude && est.lng > STAND.longitude);
});

test('uncertainty sector spans the bearing ±11.25° and the distance range', () => {
  const pts = C.uncertaintySector(STAND.latitude, STAND.longitude, 45, '50-75');
  assert.ok(pts.length >= 10);
  pts.forEach(([lat, lng]) => {
    const d = C.distanceMeters(STAND.latitude, STAND.longitude, lat, lng);
    const b = C.initialBearing(STAND.latitude, STAND.longitude, lat, lng);
    assert.ok(d >= 50 * 0.9144 - 0.01 && d <= 75 * 0.9144 + 0.01);
    assert.ok(b >= 45 - 11.26 && b <= 45 + 11.26);
  });
  // the 0–25 yard sector is a wedge that includes the stand itself
  const wedge = C.uncertaintySector(STAND.latitude, STAND.longitude, 0, '0-25');
  assert.deepEqual(wedge[wedge.length - 1], [STAND.latitude, STAND.longitude]);
});

test('ray to viewport edge (gunshot arrow end point)', () => {
  // center of a 400×300 viewport, heading east, 20px margin => x = 380
  let r = C.rayToRectEdge(200, 150, 90, 400, 300, 20);
  assert.ok(Math.abs(r.x - 380) < 1e-9 && Math.abs(r.y - 150) < 1e-9);
  r = C.rayToRectEdge(200, 150, 0, 400, 300, 20); // north => y = 20
  assert.ok(Math.abs(r.y - 20) < 1e-9 && Math.abs(r.x - 200) < 1e-9);
  r = C.rayToRectEdge(200, 150, 225, 400, 300, 0); // SW hits the bottom edge first
  assert.ok(Math.abs(r.y - 300) < 1e-9 && Math.abs(r.x - 50) < 1e-9);
  assert.equal(C.rayToRectEdge(-5, 10, 90, 400, 300, 0), null); // off-screen stand
});

test('buildSighting produces a valid, complete record', () => {
  const s = C.buildSighting({
    hunter_id: HUNTER, stand: STAND, session_id: SESSION, observed_at: '2026-11-20T12:12:00.000Z',
    first_seen_direction: 'NE', distance_range: '50-75', heading_direction: 'SW', quantity: 2, deer_type: 'doe'
  });
  assert.deepEqual(C.validateSighting(s), []);
  assert.ok(C.isUuid(s.id));
  assert.equal(s.first_seen_bearing, 45);
  assert.equal(s.heading_bearing, 225);
  assert.equal(s.distance_min_yards, 50);
  assert.equal(s.distance_max_yards, 75);
  assert.equal(s.stand_latitude, 38.5);
  assert.equal(s.status, 'active');
  assert.equal(s.observed_at, '2026-11-20T12:12:00.000Z');
  // NOT SURE heading
  const n = C.buildSighting({ hunter_id: HUNTER, stand: STAND, session_id: SESSION, observed_at: '2026-11-20T12:12:00.000Z',
    first_seen_direction: 'E', distance_range: '0-25', heading_direction: null, quantity: 1, deer_type: 'buck' });
  assert.equal(n.heading_direction, null);
  assert.equal(n.heading_bearing, null);
  assert.deepEqual(C.validateSighting(n), []);
});

test('validation rejects bad sightings and gunshots', () => {
  const base = C.buildSighting({ hunter_id: HUNTER, stand: STAND, session_id: SESSION, observed_at: '2026-11-20T12:12:00.000Z',
    first_seen_direction: 'NE', distance_range: '50-75', heading_direction: 'SW', quantity: 2, deer_type: 'doe' });
  assert.ok(C.validateSighting(Object.assign({}, base, { quantity: 0 })).length);
  assert.ok(C.validateSighting(Object.assign({}, base, { first_seen_bearing: 90 })).length);
  assert.ok(C.validateSighting(Object.assign({}, base, { deer_type: 'elk' })).length);
  assert.ok(C.validateSighting(Object.assign({}, base, { distance_range: '200-300' })).length);
  assert.ok(C.validateSighting(Object.assign({}, base, { observed_at: 'yesterday' })).length);
  const g = C.buildGunshot({ hunter_id: HUNTER, stand: STAND, session_id: SESSION, observed_at: '2026-11-20T12:28:00.000Z', direction: 'NW' });
  assert.deepEqual(C.validateGunshot(g), []);
  assert.equal(g.bearing, 315);
  assert.ok(C.validateGunshot(Object.assign({}, g, { direction: 'Q' })).length);
  assert.ok(C.validateGunshot(Object.assign({}, g, { bearing: 300 })).length);
});

test('toServer strips local-only fields', () => {
  const g = C.buildGunshot({ hunter_id: HUNTER, stand: STAND, session_id: SESSION, observed_at: '2026-11-20T12:28:00.000Z', direction: 'NW' });
  g._sync = 'pending'; g._rev = 3;
  const out = C.toServer('gunshot_reports', g);
  assert.equal(out._sync, undefined);
  assert.equal(out._rev, undefined);
  assert.equal(out.direction, 'NW');
  assert.ok(!Object.keys(out).some((k) => /propert/i.test(k)));
});

function sampleData() {
  const stand2 = { id: '22222222-2222-4222-8222-222222222222', name: 'Creek Stand', latitude: 38.505, longitude: -90.49 };
  const s1 = { id: SESSION, hunter_id: HUNTER, stand_id: STAND.id, started_at: '2026-11-20T11:00:00.000Z', ended_at: '2026-11-20T15:00:00.000Z', stand_latitude: 38.5, stand_longitude: -90.5 };
  const s2 = { id: '66666666-6666-4666-8666-666666666666', hunter_id: '00000000-0000-4000-8000-00000000000c', stand_id: stand2.id, started_at: '2026-11-21T11:00:00.000Z', ended_at: null, stand_latitude: 38.505, stand_longitude: -90.49 };
  const d1 = C.buildSighting({ hunter_id: HUNTER, stand: STAND, session_id: SESSION, observed_at: '2026-11-20T13:12:00.000Z',
    first_seen_direction: 'NE', distance_range: '50-75', heading_direction: 'SW', quantity: 2, deer_type: 'doe' });
  const g1 = C.buildGunshot({ hunter_id: s2.hunter_id, stand: stand2, session_id: s2.id, observed_at: '2026-11-21T13:28:00.000Z', direction: 'NW' });
  return {
    stands: [STAND, stand2],
    hunters: [{ id: HUNTER, display_name: 'Mike', is_admin: false }, { id: s2.hunter_id, display_name: 'John' }],
    sessions: [s1, s2], sightings: [Object.assign({ _sync: 'synced', _rev: 1 }, d1)], gunshots: [g1]
  };
}

test('export → import round trip preserves ids, timestamps, bearings', () => {
  const data = sampleData();
  const exp = C.buildExport(data, { type: 'all' }, '2026-11-22T00:00:00.000Z');
  assert.equal(exp.schema, 'deer-camp-hunt-export');
  assert.equal(exp.schema_version, 2);
  assert.equal(exp.deer_sightings[0].doe_count, 2);
  assert.equal(exp.stands.length, 2);
  assert.equal(exp.deer_sightings.length, 1);
  assert.equal(exp.gunshot_reports.length, 1);
  assert.ok(!JSON.stringify(exp).includes('_sync'));
  assert.ok(!/propert/i.test(JSON.stringify(exp)));
  assert.deepEqual(exp.hunters.map((h) => Object.keys(h).sort()), [['display_name', 'id'], ['display_name', 'id']]);
  const parsed = JSON.parse(JSON.stringify(exp));
  const v = C.validateImport(parsed);
  assert.ok(v.ok, v.errors.join());
  assert.deepEqual(v.skipped, []);
  const orig = data.sightings[0], back = v.data.sightings[0];
  ['id', 'observed_at', 'first_seen_bearing', 'heading_bearing', 'distance_range', 'quantity', 'deer_type', 'stand_latitude', 'stand_longitude', 'est_latitude', 'est_longitude']
    .forEach((k) => assert.equal(back[k], orig[k], k));
  assert.equal(v.data.gunshots[0].bearing, 315);
  assert.equal(v.data.gunshots[0].observed_at, '2026-11-21T13:28:00.000Z');
});

test('export by session includes only that hunt', () => {
  const exp = C.buildExport(sampleData(), { type: 'session', session_id: SESSION });
  assert.equal(exp.sessions.length, 1);
  assert.equal(exp.deer_sightings.length, 1);
  assert.equal(exp.gunshot_reports.length, 0);
  assert.deepEqual(exp.stands.map((s) => s.name), ['North Ridge']);
});

test('export by date range filters on original observation time', () => {
  const data = sampleData();
  const day = C.localDateKey('2026-11-21T13:28:00.000Z');
  const exp = C.buildExport(data, { type: 'range', from: day, to: day });
  assert.equal(exp.gunshot_reports.length, 1);
  assert.equal(exp.deer_sightings.length, C.localDateKey(data.sightings[0].observed_at) === day ? 1 : 0);
});

test('version-1 export files (no per-type counts) still import', () => {
  const exp = JSON.parse(JSON.stringify(C.buildExport(sampleData(), { type: 'all' })));
  exp.schema_version = 1;
  exp.deer_sightings.forEach((d) => { delete d.buck_count; delete d.doe_count; delete d.fawn_count; delete d.unknown_count; });
  const v = C.validateImport(exp);
  assert.ok(v.ok, v.errors.join());
  assert.deepEqual(v.skipped, []);
  assert.equal(v.data.sightings[0].doe_count, 2);
});

test('import validation rejects wrong files and skips bad records', () => {
  assert.equal(C.validateImport([]).ok, false);
  assert.equal(C.validateImport({ hello: 1 }).ok, false);
  assert.equal(C.validateImport({ schema: 'deer-camp-hunt-export', schema_version: 99, stands: [], sessions: [], deer_sightings: [], gunshot_reports: [] }).ok, false);
  const exp = JSON.parse(JSON.stringify(C.buildExport(sampleData(), { type: 'all' })));
  exp.deer_sightings.push(Object.assign({}, exp.deer_sightings[0], { id: 'not-a-uuid' }));
  exp.deer_sightings.push(Object.assign({}, exp.deer_sightings[0])); // duplicate id inside file
  const v = C.validateImport(exp);
  assert.ok(v.ok);
  assert.equal(v.data.sightings.length, 1);
  assert.equal(v.skipped.length, 1);
});

test('timeline orders by original observation time', () => {
  const d = sampleData();
  const late = Object.assign({}, d.sightings[0], { id: C.uuid(), observed_at: '2026-11-22T09:00:00.000Z' });
  const tl = C.timeline([late, d.sightings[0]], d.gunshots);
  assert.deepEqual(tl.map((e) => e.kind), ['deer', 'gunshot', 'deer']);
  for (let i = 1; i < tl.length; i++) assert.ok(tl[i].t >= tl[i - 1].t);
});

test('pickWeather never invents values and labels freshness', () => {
  const now = Date.parse('2026-11-20T13:00:00Z');
  const cache = {
    retrieved_at: '2026-11-20T12:50:00Z',
    current: { time: '2026-11-20T12:45:00Z', temperature_2m: 41.2, wind_speed_10m: 8, wind_direction_10m: 310, pressure_msl: 1016.4, precipitation: 0, weather_code: 3 },
    hourly: { time: ['2026-11-20T12:00:00Z', '2026-11-20T13:00:00Z'], temperature_2m: [40, 42], wind_speed_10m: [7, 9], wind_direction_10m: [300, 320], pressure_msl: [1016, null], precipitation: [0, 0], weather_code: [3, 2] }
  };
  const w = C.pickWeather(cache, '2026-11-20T12:50:00Z', now);
  assert.equal(w.source, 'open-meteo');
  assert.equal(w.kind, 'forecast');
  assert.equal(w.temperature_f, 41.2);
  assert.equal(w.conditions, 'Overcast');
  const h = C.pickWeather(Object.assign({}, cache, { current: null }), '2026-11-20T13:10:00Z', now);
  assert.equal(h.pressure_hpa, null); // missing stays missing
  assert.equal(h.temperature_f, 42);
  const old = C.pickWeather(cache, '2026-11-20T12:50:00Z', now + 3 * 3600000);
  assert.equal(old.kind, 'cached');
  assert.equal(C.pickWeather(cache, '2026-11-25T12:00:00Z', now), null); // too far from any data
  assert.equal(C.pickWeather(null, '2026-11-20T12:00:00Z', now), null);
});

test('deer labels', () => {
  assert.equal(C.deerLabel(1, 'buck'), '1 Buck');
  assert.equal(C.deerLabel(2, 'doe'), '2 Does');
  assert.equal(C.deerLabel(1, 'fawn'), '1 Fawn');
  assert.equal(C.deerLabel(3, 'unknown'), '3 Unknown');
  assert.equal(C.deerLabel({ quantity: 6, buck_count: 1, doe_count: 3, fawn_count: 2, unknown_count: 0 }), '1 Buck, 3 Does, 2 Fawns');
});

test('mixed group: one sighting with bucks, does and fawns', () => {
  const s = C.buildSighting({ hunter_id: HUNTER, stand: STAND, session_id: SESSION, observed_at: '2026-11-20T12:40:00.000Z',
    first_seen_direction: 'E', distance_range: '25-50', heading_direction: 'N', counts: { doe: 3, buck: 1, fawn: 2 } });
  assert.deepEqual(C.validateSighting(s), []);
  assert.equal(s.quantity, 6);
  assert.equal(s.deer_type, 'mixed');
  assert.deepEqual([s.buck_count, s.doe_count, s.fawn_count, s.unknown_count], [1, 3, 2, 0]);
  // a single type is still that type
  const f = C.buildSighting({ hunter_id: HUNTER, stand: STAND, session_id: SESSION, observed_at: '2026-11-20T12:40:00.000Z',
    first_seen_direction: 'E', distance_range: '25-50', counts: { fawn: 2 } });
  assert.equal(f.deer_type, 'fawn');
  assert.deepEqual(C.validateSighting(f), []);
  // totals and types must agree
  assert.ok(C.validateSighting(Object.assign({}, s, { quantity: 5 })).length);
  assert.ok(C.validateSighting(Object.assign({}, s, { deer_type: 'doe' })).length);
  assert.ok(C.validateSighting(Object.assign({}, s, { fawn_count: -1 })).length);
});

test('older single-type records are read as counts', () => {
  const old = { quantity: 2, deer_type: 'doe' };
  assert.deepEqual(C.deerCounts(old), { buck: 0, doe: 2, fawn: 0, unknown: 0 });
  const n = C.normalizeSighting(old);
  assert.equal(n.doe_count, 2);
  assert.equal(n.buck_count, 0);
  assert.equal(old.doe_count, undefined, 'original object not changed');
});
