/*
 * In-memory stand-in for the small part of Supabase (Auth + PostgREST) that
 * Deer Camp uses, served through Playwright request routing. It mimics the
 * database's ownership rule (hunter_id must be the signed-in user) and the
 * upsert-by-id behaviour so synchronization can be tested end to end without
 * a live project. It is NOT a full Supabase emulator.
 */
const crypto = require('crypto');

const b64url = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
function jwt(user) {
  const now = Math.floor(Date.now() / 1000);
  return b64url({ alg: 'HS256', typ: 'JWT' }) + '.' +
    b64url({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp: now + 3600, iat: now }) + '.sig';
}

class FakeSupabase {
  constructor(base) {
    this.base = base.replace(/\/$/, '');
    this.users = [];
    this.tables = { profiles: [], stands: [], hunting_sessions: [], deer_sightings: [], gunshot_reports: [], hunter_invites: [] };
    this.writes = []; // log of {table, id, method}
    this.down = false;          // simulate no connectivity to Supabase
    this.dropNextUpsertResponse = 0; // save on server but lose the response (tests idempotency)
  }
  addUser(email, password, displayName, opts) {
    const id = crypto.randomUUID();
    this.users.push({ id, email, password });
    this.tables.profiles.push({ id, display_name: displayName, is_admin: !!(opts && opts.admin), is_active: opts && opts.active === false ? false : true });
    return id;
  }
  addStand(name, lat, lng) {
    const s = { id: crypto.randomUUID(), name, latitude: lat, longitude: lng, description: null, is_active: true, updated_at: new Date().toISOString() };
    this.tables.stands.push(s);
    return s;
  }
  userFromAuth(headers) {
    const h = headers['authorization'] || '';
    const tok = h.replace(/^Bearer\s+/i, '');
    try {
      const payload = JSON.parse(Buffer.from(tok.split('.')[1], 'base64url').toString());
      return this.users.find((u) => u.id === payload.sub) || null;
    } catch (_) { return null; }
  }
  json(route, status, body, extraHeaders) {
    return route.fulfill({
      status, contentType: 'application/json',
      headers: Object.assign({ 'access-control-allow-origin': '*' }, extraHeaders || {}),
      body: body === undefined ? '' : JSON.stringify(body)
    });
  }
  async handle(route) {
    const req = route.request();
    const url = new URL(req.url());
    if (req.method() === 'OPTIONS') {
      return route.fulfill({ status: 204, headers: { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' } });
    }
    if (this.down) return route.abort('internetdisconnected');
    const path = url.pathname;
    const headers = req.headers();
    if (path.startsWith('/auth/v1/')) return this.auth(route, req, url, path, headers);
    if (path.startsWith('/rest/v1/')) return this.rest(route, req, url, path.slice('/rest/v1/'.length), headers);
    return route.abort('failed');
  }
  session(user) {
    return {
      access_token: jwt(user), token_type: 'bearer', expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600,
      refresh_token: 'refresh-' + user.id,
      user: { id: user.id, aud: 'authenticated', role: 'authenticated', email: user.email, app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
    };
  }
  auth(route, req, url, path, headers) {
    const body = req.postDataJSON ? (() => { try { return req.postDataJSON(); } catch (_) { return {}; } })() : {};
    if (path === '/auth/v1/token') {
      const gt = url.searchParams.get('grant_type');
      let user = null;
      if (gt === 'password') user = this.users.find((u) => u.email === body.email && u.password === body.password);
      if (gt === 'refresh_token') user = this.users.find((u) => 'refresh-' + u.id === body.refresh_token);
      if (!user) return this.json(route, 400, { error: 'invalid_grant', error_description: 'Invalid login credentials', code: 'invalid_credentials', msg: 'Invalid login credentials' });
      return this.json(route, 200, this.session(user));
    }
    if (path === '/auth/v1/user') {
      const u = this.userFromAuth(headers);
      if (!u) return this.json(route, 401, { msg: 'invalid JWT' });
      return this.json(route, 200, this.session(u).user);
    }
    if (path === '/auth/v1/logout') return route.fulfill({ status: 204, headers: { 'access-control-allow-origin': '*' } });
    if (path === '/auth/v1/signup') {
      const id = this.addUser(body.email, body.password, (body.data && body.data.display_name) || body.email, { active: false });
      return this.json(route, 200, this.session(this.users.find((u) => u.id === id)));
    }
    return this.json(route, 404, { msg: 'not found' });
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
    out = out.slice(off, lim ? off + +lim : undefined);
    return out;
  }
  async rest(route, req, url, table, headers) {
    const user = this.userFromAuth(headers);
    const rows = this.tables[table];
    if (!rows) return this.json(route, 404, { message: 'relation does not exist' });
    const me = user && this.tables.profiles.find((p) => p.id === user.id);
    const member = me && me.is_active;
    const method = req.method();
    if (method === 'GET') {
      if (!user) return this.json(route, 401, { message: 'permission denied' });
      let visible = member ? rows : (table === 'profiles' ? rows.filter((r) => r.id === user.id) : []);
      const out = this.filterRows(visible, url);
      if ((headers['accept'] || '').includes('vnd.pgrst.object')) {
        if (out.length !== 1) return this.json(route, 406, { message: 'JSON object requested, multiple (or no) rows returned', code: 'PGRST116' });
        return this.json(route, 200, out[0]);
      }
      return this.json(route, 200, out);
    }
    if (method === 'POST') {
      if (!member) return this.json(route, 403, { code: '42501', message: 'new row violates row-level security policy for table "' + table + '"' });
      let body = req.postDataJSON();
      const list = Array.isArray(body) ? body : [body];
      const saved = [];
      for (const rec of list) {
        if (['hunting_sessions', 'deer_sightings', 'gunshot_reports'].includes(table)) {
          if (rec.hunter_id !== user.id) return this.json(route, 403, { code: '42501', message: 'new row violates row-level security policy for table "' + table + '"' });
          if (table !== 'hunting_sessions' && !this.tables.hunting_sessions.some((s) => s.id === rec.session_id && s.hunter_id === user.id)) {
            return this.json(route, 403, { code: '42501', message: 'new row violates row-level security policy (session)' });
          }
        }
        const idx = rows.findIndex((r) => r.id === rec.id);
        const now = new Date().toISOString();
        const row = Object.assign({}, idx >= 0 ? rows[idx] : { server_received_at: now }, rec, { updated_at: now });
        if (idx >= 0) rows[idx] = row; else rows.push(row);
        this.writes.push({ table, id: rec.id, method: idx >= 0 ? 'update' : 'insert' });
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
