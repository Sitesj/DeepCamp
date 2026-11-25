/*
 * In-memory stand-in for the small part of Supabase (Auth + PostgREST + the
 * camp-code functions) that Deer Camp uses, served through Playwright request
 * routing. It mimics the database's rules closely enough to test the app end
 * to end without a live project:
 *   - each phone gets an anonymous account; joining links it to ONE hunter,
 *     and a hunter name can only be linked to one phone at a time
 *   - records must be written as the hunter linked to the phone
 *   - uploads are upserts by id
 * It is NOT a full Supabase emulator; tests/db checks the real SQL.
 */
const crypto = require('crypto');

const b64url = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
function jwt(user) {
  const now = Math.floor(Date.now() / 1000);
  return b64url({ alg: 'HS256', typ: 'JWT' }) + '.' +
    b64url({ sub: user.id, role: 'authenticated', aud: 'authenticated', is_anonymous: true, exp: now + 3600, iat: now }) + '.sig';
}

class FakeSupabase {
  constructor(base) {
    this.base = base.replace(/\/$/, '');
    this.users = [];                 // anonymous phone accounts
    this.devices = new Map();        // phone user id -> hunter id
    this.campCode = null;
    this.failures = new Map();       // phone user id -> wrong code count
    this.tables = { profiles: [], stands: [], hunting_sessions: [], deer_sightings: [], gunshot_reports: [] };
    this.writes = [];
    this.down = false;                 // simulate no connectivity to Supabase
    this.dropNextUpsertResponse = 0;   // save on server but lose the reply (tests idempotency)
    this.anonymousEnabled = true;
  }
  addHunter(name, opts) {
    const id = crypto.randomUUID();
    this.tables.profiles.push({ id, display_name: name, is_admin: !!(opts && opts.admin), is_active: !(opts && opts.active === false) });
    return id;
  }
  addStand(name, lat, lng) {
    const s = { id: crypto.randomUUID(), name, latitude: lat, longitude: lng, description: null, is_active: true, updated_at: new Date().toISOString() };
    this.tables.stands.push(s);
    return s;
  }
  hunterFor(user) {
    if (!user) return null;
    const hid = this.devices.get(user.id);
    const p = hid && this.tables.profiles.find((x) => x.id === hid && x.is_active);
    return p || null;
  }
  userFromAuth(headers) {
    const tok = (headers['authorization'] || '').replace(/^Bearer\s+/i, '');
    try {
      const payload = JSON.parse(Buffer.from(tok.split('.')[1], 'base64url').toString());
      return this.users.find((u) => u.id === payload.sub) || null;
    } catch (_) { return null; }
  }
  json(route, status, body) {
    return route.fulfill({ status, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' }, body: body === undefined ? '' : JSON.stringify(body) });
  }
  async handle(route) {
    const req = route.request();
    const url = new URL(req.url());
    if (req.method() === 'OPTIONS') {
      return route.fulfill({ status: 204, headers: { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' } });
    }
    if (this.down) return route.abort('internetdisconnected');
    const headers = req.headers();
    if (url.pathname.startsWith('/auth/v1/')) return this.auth(route, req, url, headers);
    if (url.pathname.startsWith('/rest/v1/rpc/')) return this.rpc(route, req, url.pathname.slice('/rest/v1/rpc/'.length), headers);
    if (url.pathname.startsWith('/rest/v1/')) return this.rest(route, req, url, url.pathname.slice('/rest/v1/'.length), headers);
    return route.abort('failed');
  }
  session(user) {
    return {
      access_token: jwt(user), token_type: 'bearer', expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600,
      refresh_token: 'refresh-' + user.id,
      user: { id: user.id, aud: 'authenticated', role: 'authenticated', is_anonymous: true, app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
    };
  }
  auth(route, req, url, headers) {
    let body = {};
    try { body = req.postDataJSON() || {}; } catch (_) {}
    const path = url.pathname;
    if (path === '/auth/v1/signup') {            // signInAnonymously()
      if (!this.anonymousEnabled) return this.json(route, 422, { code: 'anonymous_provider_disabled', msg: 'Anonymous sign-ins are disabled', error_code: 'anonymous_provider_disabled' });
      const user = { id: crypto.randomUUID() };
      this.users.push(user);
      return this.json(route, 200, this.session(user));
    }
    if (path === '/auth/v1/token' && url.searchParams.get('grant_type') === 'refresh_token') {
      const user = this.users.find((u) => 'refresh-' + u.id === body.refresh_token);
      if (!user) return this.json(route, 400, { error: 'invalid_grant', error_description: 'Invalid Refresh Token' });
      return this.json(route, 200, this.session(user));
    }
    if (path === '/auth/v1/user') {
      const u = this.userFromAuth(headers);
      return u ? this.json(route, 200, this.session(u).user) : this.json(route, 401, { msg: 'invalid JWT' });
    }
    if (path === '/auth/v1/logout') return route.fulfill({ status: 204, headers: { 'access-control-allow-origin': '*' } });
    return this.json(route, 404, { msg: 'not found' });
  }
  checkCode(user, code) {
    if (!user) return 'not_signed_in';
    if (!this.campCode) return 'not_set';
    if ((this.failures.get(user.id) || 0) >= 5) return 'locked';
    if (String(code || '').trim() === this.campCode) { this.failures.delete(user.id); return 'ok'; }
    this.failures.set(user.id, (this.failures.get(user.id) || 0) + 1);
    return 'wrong';
  }
  rpc(route, req, fn, headers) {
    const user = this.userFromAuth(headers);
    if (!user) return this.json(route, 401, { message: 'permission denied for function ' + fn });
    let a = {};
    try { a = req.postDataJSON() || {}; } catch (_) {}
    const me = this.hunterFor(user);
    const inUseBy = (hid) => [...this.devices.entries()].find(([uid, h]) => h === hid && uid !== user.id);
    if (fn === 'camp_roster') {
      const r = this.checkCode(user, a.code);
      if (r !== 'ok') return this.json(route, 200, { ok: false, error: r });
      return this.json(route, 200, { ok: true, hunters: this.tables.profiles.filter((p) => p.is_active)
        .map((p) => ({ id: p.id, display_name: p.display_name, in_use: !!inUseBy(p.id), mine: this.devices.get(user.id) === p.id })) });
    }
    if (fn === 'join_camp') {
      const r = this.checkCode(user, a.code);
      if (r !== 'ok') return this.json(route, 200, { ok: false, error: r });
      const p = this.tables.profiles.find((x) => x.id === a.hunter && x.is_active);
      if (!p) return this.json(route, 200, { ok: false, error: 'no_such_hunter' });
      if (inUseBy(p.id)) return this.json(route, 200, { ok: false, error: 'in_use' });
      this.devices.set(user.id, p.id);
      return this.json(route, 200, { ok: true, hunter: { id: p.id, display_name: p.display_name, is_admin: p.is_admin } });
    }
    if (fn === 'whoami') return this.json(route, 200, { hunter: me ? { id: me.id, display_name: me.display_name, is_admin: me.is_admin } : null });
    if (fn === 'leave_camp') { this.devices.delete(user.id); return this.json(route, 200, null); }
    if (!me || !me.is_admin) return this.json(route, 403, { code: '42501', message: 'Only the camp administrator can do this' });
    if (fn === 'release_hunter') { for (const [uid, h] of this.devices) if (h === a.hunter) this.devices.delete(uid); return this.json(route, 200, null); }
    if (fn === 'set_camp_code') { this.campCode = String(a.code).trim(); this.failures.clear(); return this.json(route, 200, null); }
    if (fn === 'hunter_list') {
      return this.json(route, 200, this.tables.profiles.map((p) => ({ ...p, in_use: [...this.devices.values()].includes(p.id), last_seen_at: null })));
    }
    return this.json(route, 404, { message: 'function not found' });
  }
  filterRows(rows, url) {
    let out = rows.slice();
    for (const [k, v] of url.searchParams) {
      if (['select', 'order', 'limit', 'offset', 'on_conflict', 'columns'].includes(k)) continue;
      const m = /^(eq|gte|gt|lte|lt)\.(.*)$/.exec(v);
      if (!m) continue;
      const [, op, val] = m;
      out = out.filter((r) => {
        const a = r[k];
        if (op === 'eq') return String(a) === val;
        const x = Date.parse(a), y = Date.parse(val);
        if (op === 'gte') return x >= y; if (op === 'gt') return x > y; if (op === 'lte') return x <= y; return x < y;
      });
    }
    const order = url.searchParams.get('order');
    if (order) {
      const [col, dir] = order.split('.');
      out.sort((a, b) => (String(a[col]) < String(b[col]) ? -1 : String(a[col]) > String(b[col]) ? 1 : 0) * (dir === 'desc' ? -1 : 1));
    }
    const off = +(url.searchParams.get('offset') || 0);
    const lim = url.searchParams.get('limit');
    return out.slice(off, lim ? off + +lim : undefined);
  }
  async rest(route, req, url, table, headers) {
    const user = this.userFromAuth(headers);
    const rows = this.tables[table];
    if (!rows) return this.json(route, 404, { message: 'relation does not exist' });
    const me = this.hunterFor(user);
    const method = req.method();
    if (method === 'GET') {
      if (!user) return this.json(route, 401, { message: 'permission denied' });
      return this.json(route, 200, me ? this.filterRows(rows, url) : []);
    }
    const denied = () => this.json(route, 403, { code: '42501', message: 'new row violates row-level security policy for table "' + table + '"' });
    if (method === 'POST') {
      if (!me) return denied();
      if ((table === 'profiles' || table === 'stands') && !me.is_admin) return denied();
      const body = req.postDataJSON();
      const list = Array.isArray(body) ? body : [body];
      const saved = [];
      for (const rec of list) {
        if (['hunting_sessions', 'deer_sightings', 'gunshot_reports'].includes(table)) {
          if (rec.hunter_id !== me.id) return denied();
          if (table !== 'hunting_sessions' && !this.tables.hunting_sessions.some((s) => s.id === rec.session_id && s.hunter_id === me.id)) return denied();
        }
        const id = rec.id || crypto.randomUUID();
        const idx = rows.findIndex((r) => r.id === id);
        const now = new Date().toISOString();
        const row = Object.assign({}, idx >= 0 ? rows[idx] : { server_received_at: now }, rec, { id, updated_at: now });
        if (idx >= 0) rows[idx] = row; else rows.push(row);
        this.writes.push({ table, id, method: idx >= 0 ? 'update' : 'insert' });
        saved.push(row);
      }
      if (this.dropNextUpsertResponse > 0) { this.dropNextUpsertResponse--; return route.abort('connectionreset'); }
      return this.json(route, 201, saved);
    }
    if (method === 'PATCH') {
      if (!me || !me.is_admin) return this.json(route, 200, []);
      const patch = req.postDataJSON();
      const targets = this.filterRows(rows, url);
      targets.forEach((r) => Object.assign(r, patch, { updated_at: new Date().toISOString() }));
      return this.json(route, 200, targets);
    }
    return this.json(route, 405, { message: 'method not allowed' });
  }
}

module.exports = { FakeSupabase };
