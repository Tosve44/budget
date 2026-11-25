// TEST ONLY: a small stand-in for a hosted Supabase project, so the real supabase-js library
// in the app can be tested end to end without internet. It speaks the same HTTP API for the
// parts the app uses (sign-up/sign-in, table reads and writes, RPC calls, photo storage) and
// runs every request against a real Postgres as the signed-in user, exactly like Supabase,
// so the migration's row level security is what decides what each phone can see.
//
// Not a full Supabase: only the query features sync.js uses are supported.
// Run: PGURL=... PORT=54321 node tests/backend/fake-supabase.cjs

const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { Pool } = require('pg');

const PORT = Number(process.env.PORT || 54321);
const SECRET = 'test-secret-not-for-production';
const STORE_DIR = process.env.STORE_DIR || path.join(require('node:os').tmpdir(), 'fake-supabase-files');
fs.mkdirSync(STORE_DIR, { recursive: true });
const pool = new Pool({ connectionString: process.env.PGURL || 'postgres://postgres@/budget_test?host=/tmp&port=54329', max: 8 });

// simulated network trouble, switched on by tests through /__test/faults
const faults = { failNext: 0, delayMs: 0 };

// ---------- tiny JWT ----------
const b64u = (b) => Buffer.from(b).toString('base64url');
function sign(payload) {
  const h = b64u(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const p = b64u(JSON.stringify(payload));
  return `${h}.${p}.${crypto.createHmac('sha256', SECRET).update(`${h}.${p}`).digest('base64url')}`;
}
function verify(token) {
  const [h, p, s] = String(token || '').split('.');
  if (!s) return null;
  const good = crypto.createHmac('sha256', SECRET).update(`${h}.${p}`).digest('base64url');
  if (good !== s) return null;
  const payload = JSON.parse(Buffer.from(p, 'base64url').toString());
  if (payload.exp && payload.exp < Date.now() / 1000) return null;
  return payload;
}
const ANON_KEY = sign({ role: 'anon', iss: 'fake-supabase' });

function session(user) {
  const exp = Math.floor(Date.now() / 1000) + 3600;
  const access_token = sign({ sub: user.id, role: 'authenticated', email: user.email, exp, aud: 'authenticated' });
  return {
    access_token, token_type: 'bearer', expires_in: 3600, expires_at: exp,
    refresh_token: b64u(crypto.randomBytes(24)) + '.' + b64u(user.id),
    user: userJson(user),
  };
}
function userJson(u) {
  return { id: u.id, aud: 'authenticated', role: 'authenticated', email: u.email, email_confirmed_at: u.created_at, app_metadata: { provider: 'email' }, user_metadata: {}, created_at: u.created_at, updated_at: u.created_at };
}

// ---------- helpers ----------
function send(res, status, body, headers = {}) {
  const isBuf = Buffer.isBuffer(body);
  res.writeHead(status, {
    'content-type': isBuf ? headers['content-type'] || 'application/octet-stream' : 'application/json',
    'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*',
    'access-control-expose-headers': 'content-range, content-type', ...headers,
  });
  res.end(isBuf ? body : body === undefined ? '' : JSON.stringify(body));
}
const readBody = (req) => new Promise((resolve) => { const c = []; req.on('data', (d) => c.push(d)); req.on('end', () => resolve(Buffer.concat(c))); });
const pgErr = (res, e) => {
  const status = e.code === '42501' ? 403 : e.code === '23505' ? 409 : e.code === 'P0002' ? 404 : 400;
  send(res, status, { code: e.code, message: e.message, details: e.detail || null, hint: e.hint || null });
};
const ident = (s) => { if (!/^[a-z_][a-z0-9_]*$/.test(s)) throw Object.assign(new Error(`bad name ${s}`), { code: 'PGRST100' }); return `"${s}"`; };

async function asRole(claims, fn) {
  const c = await pool.connect();
  try {
    await c.query('begin');
    await c.query(`set local role ${claims.role === 'authenticated' ? 'authenticated' : 'anon'}`);
    await c.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify(claims)]);
    const out = await fn(c);
    await c.query('commit');
    return out;
  } catch (e) {
    await c.query('rollback').catch(() => {});
    throw e;
  } finally {
    c.release();
  }
}

// PostgREST-style filters: col=op.value
function parseFilters(params, args) {
  const where = [];
  for (const [k, v] of params) {
    if (['select', 'order', 'limit', 'offset', 'on_conflict', 'columns'].includes(k)) continue;
    const m = /^(eq|neq|gt|gte|lt|lte|in|is)\.(.*)$/s.exec(v);
    if (!m) throw Object.assign(new Error(`unsupported filter ${k}=${v}`), { code: 'PGRST100' });
    const [, op, raw] = m;
    const col = ident(k);
    if (op === 'in') {
      const vals = raw.replace(/^\(|\)$/g, '').split(',').map((x) => x.replace(/^"|"$/g, ''));
      args.push(vals); where.push(`${col}::text = any($${args.length})`);
    } else if (op === 'is') {
      where.push(`${col} is ${raw === 'null' ? 'null' : raw === 'true' ? 'true' : 'false'}`);
    } else {
      const sym = { eq: '=', neq: '<>', gt: '>', gte: '>=', lt: '<', lte: '<=' }[op];
      args.push(raw); where.push(`${col} ${sym} $${args.length}`);
    }
  }
  return where.length ? ` where ${where.join(' and ')}` : '';
}
function parseSelect(sel) {
  if (!sel || sel === '*') return '*';
  return sel.split(',').map((c) => ident(c.trim())).join(', ');
}
function parseOrder(order) {
  if (!order) return '';
  return ' order by ' + order.split(',').map((p) => { const [c, dir] = p.split('.'); return `${ident(c)} ${dir === 'desc' ? 'desc' : 'asc'}`; }).join(', ');
}

// ---------- handlers ----------
async function auth(req, res, url, body) {
  const route = url.pathname.replace('/auth/v1', '');
  if (route === '/signup' && req.method === 'POST') {
    const { email, password } = JSON.parse(body || '{}');
    if (!email || !password || password.length < 6) return send(res, 422, { code: 422, error_code: 'weak_password', msg: 'Password should be at least 6 characters.' });
    const hash = crypto.createHash('sha256').update(password).digest('hex');
    try {
      const r = await pool.query('insert into auth.users (email, encrypted_password) values (lower($1), $2) returning *', [email, hash]);
      return send(res, 200, session(r.rows[0]));
    } catch (e) {
      if (e.code === '23505') return send(res, 422, { code: 422, error_code: 'user_already_exists', msg: 'User already registered' });
      throw e;
    }
  }
  if (route === '/token' && req.method === 'POST') {
    const grant = url.searchParams.get('grant_type');
    const b = JSON.parse(body || '{}');
    if (grant === 'password') {
      const hash = crypto.createHash('sha256').update(b.password || '').digest('hex');
      const r = await pool.query('select * from auth.users where email = lower($1) and encrypted_password = $2', [b.email, hash]);
      if (!r.rows[0]) return send(res, 400, { code: 400, error_code: 'invalid_credentials', msg: 'Invalid login credentials' });
      return send(res, 200, session(r.rows[0]));
    }
    if (grant === 'refresh_token') {
      const id = Buffer.from(String(b.refresh_token).split('.')[1] || '', 'base64url').toString();
      const r = await pool.query('select * from auth.users where id::text = $1', [id]);
      if (!r.rows[0]) return send(res, 400, { code: 400, error_code: 'refresh_token_not_found', msg: 'Invalid Refresh Token' });
      return send(res, 200, session(r.rows[0]));
    }
  }
  if (route === '/user' && req.method === 'GET') {
    const claims = verify((req.headers.authorization || '').replace(/^Bearer /i, ''));
    if (!claims?.sub) return send(res, 401, { code: 401, msg: 'invalid JWT' });
    const r = await pool.query('select * from auth.users where id = $1', [claims.sub]);
    return send(res, 200, userJson(r.rows[0]));
  }
  if (route === '/logout') return send(res, 204);
  return send(res, 404, { msg: `not supported: ${req.method} ${route}` });
}

async function rest(req, res, url, body, claims) {
  const route = url.pathname.replace('/rest/v1/', '');
  const prefer = req.headers.prefer || '';
  const wantObject = /vnd\.pgrst\.object/.test(req.headers.accept || '');
  const returnRep = /return=representation/.test(prefer);
  if (route.startsWith('rpc/')) {
    const fn = ident(route.slice(4));
    const a = JSON.parse(body || '{}');
    const names = Object.keys(a);
    const rows = await asRole(claims, (c) => c.query(`select to_json(r) as j from public.${fn}(${names.map((n, i) => `${ident(n)} => $${i + 1}`).join(', ')}) r`, names.map((n) => a[n])));
    return send(res, 200, rows.rows[0]?.j ?? null);
  }
  const table = `public.${ident(route)}`;
  const args = [];
  const params = url.searchParams;
  const sel = parseSelect(params.get('select'));
  if (req.method === 'GET') {
    const where = parseFilters(params, args);
    let sql = `select ${sel} from ${table}${where}${parseOrder(params.get('order'))}`;
    if (params.get('limit')) sql += ` limit ${Number(params.get('limit'))}`;
    if (params.get('offset')) sql += ` offset ${Number(params.get('offset'))}`;
    const out = await asRole(claims, (c) => c.query(`select coalesce(json_agg(t), '[]'::json) as j from (${sql}) t`, args));
    const rows = out.rows[0].j;
    if (wantObject) return rows.length === 1 ? send(res, 200, rows[0]) : send(res, 406, { code: 'PGRST116', message: 'JSON object requested, multiple (or no) rows returned', details: `The result contains ${rows.length} rows` });
    return send(res, 200, rows, { 'content-range': `0-${rows.length - 1}/*` });
  }
  if (req.method === 'POST') {
    let rows = JSON.parse(body || '[]');
    if (!Array.isArray(rows)) rows = [rows];
    if (!rows.length) return send(res, 201, returnRep ? [] : undefined);
    const cols = [...new Set(rows.flatMap((r) => Object.keys(r)))];
    const upsert = /resolution=merge-duplicates/.test(prefer);
    const conflict = params.get('on_conflict') || 'id';
    const sql = `insert into ${table} (${cols.map(ident).join(', ')})
      select ${cols.map(ident).join(', ')} from json_populate_recordset(null::${table}, $1::json)
      ${upsert ? `on conflict (${ident(conflict)}) do update set ${cols.filter((c) => c !== conflict).map((c) => `${ident(c)} = excluded.${ident(c)}`).join(', ')}` : ''}
      returning ${sel}`;
    const out = await asRole(claims, (c) => c.query(`with w as (${sql}) select coalesce(json_agg(w), '[]'::json) as j from w`, [JSON.stringify(rows)]));
    return send(res, 201, returnRep ? out.rows[0].j : undefined);
  }
  if (req.method === 'PATCH') {
    const patch = JSON.parse(body || '{}');
    const cols = Object.keys(patch);
    args.push(JSON.stringify(patch));
    const where = parseFilters(params, args);
    const sql = `update ${table} set ${cols.map((c) => `${ident(c)} = (json_populate_record(null::${table}, $1::json)).${ident(c)}`).join(', ')}${where} returning ${sel}`;
    const out = await asRole(claims, (c) => c.query(`with w as (${sql}) select coalesce(json_agg(w), '[]'::json) as j from w`, args));
    return send(res, 200, returnRep ? out.rows[0].j : undefined);
  }
  return send(res, 405, { message: 'method not supported' });
}

function parseMultipart(buf, contentType) {
  const boundary = /boundary=(?:"([^"]+)"|([^;]+))/.exec(contentType || '');
  if (!boundary) return buf;
  const b = Buffer.from(`--${boundary[1] || boundary[2]}`);
  let start = 0;
  const parts = [];
  while ((start = buf.indexOf(b, start)) !== -1) {
    const next = buf.indexOf(b, start + b.length);
    if (next === -1) break;
    parts.push(buf.subarray(start + b.length + 2, next - 2));
    start = next;
  }
  for (const p of parts) {
    const sep = p.indexOf('\r\n\r\n');
    const head = p.subarray(0, sep).toString();
    if (/filename=|name=""/.test(head)) return p.subarray(sep + 4);
  }
  return parts.length ? parts[parts.length - 1].subarray(parts[parts.length - 1].indexOf('\r\n\r\n') + 4) : buf;
}

async function storage(req, res, url, body, claims) {
  const lm = /^\/storage\/v1\/object\/list\/([^/]+)$/.exec(url.pathname);
  if (lm && req.method === 'POST') {
    const { prefix = '' } = JSON.parse(body.toString() || '{}');
    const p = prefix.replace(/\/$/, '') + '/';
    const rows = await asRole(claims, (c) => c.query('select id, name, created_at, updated_at, metadata from storage.objects where bucket_id = $1 and name like $2 order by name', [lm[1], p + '%']));
    return send(res, 200, rows.rows.map((r) => ({ ...r, name: r.name.slice(p.length) })));
  }
  const m = /^\/storage\/v1\/object(?:\/authenticated)?\/([^/]+)\/?(.*)$/.exec(url.pathname);
  if (!m) return send(res, 404, { statusCode: '404', error: 'not found', message: 'not found' });
  const bucket = m[1];
  const name = decodeURIComponent(m[2]);
  const file = (n) => path.join(STORE_DIR, bucket, n.replace(/\.\./g, '_'));
  if (req.method === 'POST' || req.method === 'PUT') {
    const data = parseMultipart(body, req.headers['content-type']);
    const limit = await pool.query('select file_size_limit from storage.buckets where id = $1', [bucket]);
    if (limit.rows[0]?.file_size_limit && data.length > Number(limit.rows[0].file_size_limit)) {
      return send(res, 413, { statusCode: '413', error: 'Payload too large', message: 'The object exceeded the maximum allowed size' });
    }
    const upsert = req.headers['x-upsert'] === 'true';
    try {
      await asRole(claims, async (c) => {
        const existing = await c.query('select id from storage.objects where bucket_id = $1 and name = $2', [bucket, name]);
        if (existing.rows.length) {
          if (!upsert) throw Object.assign(new Error('The resource already exists'), { code: '23505' });
          const u = await c.query('update storage.objects set updated_at = now() where bucket_id = $1 and name = $2 returning id', [bucket, name]);
          if (!u.rows.length) throw Object.assign(new Error('new row violates row-level security policy'), { code: '42501' });
        } else {
          await c.query('insert into storage.objects (bucket_id, name, owner, metadata) values ($1, $2, $3, $4)', [bucket, name, claims.sub || null, { size: data.length }]);
        }
      });
    } catch (e) {
      return send(res, e.code === '23505' ? 409 : 403, { statusCode: e.code === '23505' ? '409' : '403', error: 'Unauthorized', message: e.message });
    }
    fs.mkdirSync(path.dirname(file(name)), { recursive: true });
    fs.writeFileSync(file(name), data);
    return send(res, 200, { Key: `${bucket}/${name}`, Id: name });
  }
  if (req.method === 'GET') {
    const ok = await asRole(claims, (c) => c.query('select 1 from storage.objects where bucket_id = $1 and name = $2', [bucket, name]));
    if (!ok.rows.length || !fs.existsSync(file(name))) return send(res, 400, { statusCode: '404', error: 'not_found', message: 'Object not found' });
    return send(res, 200, fs.readFileSync(file(name)), { 'content-type': 'image/jpeg' });
  }
  if (req.method === 'DELETE') {
    const { prefixes = [] } = JSON.parse(body.toString() || '{}');
    const removed = await asRole(claims, (c) => c.query('delete from storage.objects where bucket_id = $1 and name = any($2) returning name', [bucket, prefixes]));
    removed.rows.forEach((r) => fs.rmSync(file(r.name), { force: true }));
    return send(res, 200, removed.rows.map((r) => ({ name: r.name })));
  }
  return send(res, 405, { message: 'method not supported' });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  if (req.method === 'OPTIONS') return send(res, 204);
  try {
    if (url.pathname === '/__test/faults') { Object.assign(faults, JSON.parse((await readBody(req)).toString() || '{}')); return send(res, 200, faults); }
    if (url.pathname === '/__test/anon-key') return send(res, 200, { key: ANON_KEY });
    if (faults.delayMs) await new Promise((r) => setTimeout(r, faults.delayMs));
    if (faults.failNext > 0) { faults.failNext--; req.socket.destroy(); return; }
    const body = await readBody(req);
    if (url.pathname.startsWith('/auth/v1')) return await auth(req, res, url, body.toString());
    const token = (req.headers.authorization || '').replace(/^Bearer /i, '') || req.headers.apikey;
    const claims = verify(token);
    if (!claims) return send(res, 401, { code: 'PGRST301', message: 'JWT invalid or expired' });
    if (url.pathname.startsWith('/rest/v1/')) return await rest(req, res, url, body.toString(), claims);
    if (url.pathname.startsWith('/storage/v1/')) return await storage(req, res, url, body, claims);
    send(res, 404, { message: 'not found' });
  } catch (e) {
    if (e.code) return pgErr(res, e);
    console.error(e);
    send(res, 500, { message: String(e.message) });
  }
});
server.listen(PORT, () => console.log(`fake supabase on http://localhost:${PORT}  anon key: ${ANON_KEY}`));
