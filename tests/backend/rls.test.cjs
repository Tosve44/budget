// Privacy and data rules of supabase/migrations/*.sql, tested on a real Postgres.
// Each query runs exactly like Supabase runs a phone's request: as the "authenticated"
// role with the signed-in user's id in the JWT claims, so row level security applies.
// Run: PGURL=postgres://postgres@localhost:54329/budget_test node --test tests/backend/rls.test.cjs
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { Client } = require('pg');

const db = new Client({ connectionString: process.env.PGURL || 'postgres://postgres@/budget_test?host=/tmp&port=54329' });
const ids = {};

async function as(user, sql, params = []) {
  await db.query('begin');
  try {
    if (user === 'anon') {
      await db.query("set local role anon; select set_config('request.jwt.claims', '{\"role\":\"anon\"}', true)");
    } else {
      await db.query('set local role authenticated');
      await db.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify({ sub: ids[user], role: 'authenticated' })]);
    }
    const r = await db.query(sql, params);
    await db.query('commit');
    return r.rows;
  } catch (e) {
    await db.query('rollback');
    throw e;
  }
}
const rejects = (p, re) => assert.rejects(p, re);

before(async () => {
  await db.connect();
  await db.query('truncate public.households, storage.objects cascade; delete from auth.users');
  for (const name of ['tosve', 'milica', 'stranger', 'third']) {
    const r = await db.query('insert into auth.users (email) values ($1) returning id', [`${name}@example.test`]);
    ids[name] = r.rows[0].id;
  }
});
after(() => db.end());

let invite;
test('Tosve creates the household; spaces are created for him', async () => {
  const [h] = await as('tosve', "select * from public.create_household('Tosve', 'sp_house_1', 'sp_personal_t')");
  invite = h.invite_code;
  assert.match(invite, /^[0-9A-F]{8}$/);
  const spaces = await as('tosve', 'select id, type from public.spaces order by id');
  assert.deepEqual(spaces.map((s) => s.id), ['sp_house_1', 'sp_personal_t']);
});

test('cannot create a second household or join one while already in one', async () => {
  await rejects(as('tosve', "select public.create_household('Tosve', 'sp_house_2', 'sp_personal_t2')"), /already in a household/);
  await rejects(as('tosve', "select public.join_household($1, 'Tosve', 'sp_x')", [invite]), /already in a household/);
});

test('Milica joins with the invite code (any case, spaces around it)', async () => {
  await rejects(as('milica', "select public.join_household('WRONG123', 'Milica', 'sp_personal_m')"), /invite code not found/);
  await as('milica', "select public.join_household($1, 'Milica', 'sp_personal_m')", [` ${invite.toLowerCase()} `]);
  const members = await as('milica', 'select display_name from public.members order by display_name');
  assert.deepEqual(members.map((m) => m.display_name), ['Milica', 'Tosve']);
});

test('a third person cannot join (two people max)', async () => {
  await rejects(as('third', "select public.join_household($1, 'Someone', 'sp_personal_3')", [invite]), /household is full/);
});

test('not signed in: no access at all', async () => {
  await rejects(as('anon', 'select * from public.transactions'), /permission denied/);
  await rejects(as('anon', "select public.join_household('X', 'Y', 'Z')"), /permission denied/);
});

test('set up categories and entries for the privacy tests', async () => {
  await as('tosve', `insert into public.categories (id, space_id, name, kind, budget) values
    ('c_t_gas', 'sp_personal_t', 'Gas', 'expense', 8000), ('c_h_groc', 'sp_house_1', 'Groceries', 'expense', 40000)`);
  await as('milica', `insert into public.categories (id, space_id, name, kind) values ('c_m_beauty', 'sp_personal_m', 'Beauty', 'expense')`);
  await as('tosve', `insert into public.transactions (id, space_id, category_id, kind, amount, date, created_by)
    values ('tx1', 'sp_personal_t', 'c_t_gas', 'expense', 5000, '2026-11-20', $1),
           ('tx2', 'sp_house_1', 'c_h_groc', 'expense', 3210, '2026-11-21', $1)`, [ids.tosve]);
  await as('milica', `insert into public.transactions (id, space_id, category_id, kind, amount, date, created_by)
    values ('tx3', 'sp_personal_m', 'c_m_beauty', 'expense', 2500, '2026-11-22', $1),
           ('tx4', 'sp_house_1', 'c_h_groc', 'expense', 1800, '2026-11-22', $1)`, [ids.milica]);
});

test('Personal stays private: each sees only their own personal space plus the House', async () => {
  const t = await as('tosve', 'select id from public.transactions order by id');
  assert.deepEqual(t.map((r) => r.id), ['tx1', 'tx2', 'tx4']);
  const m = await as('milica', 'select id from public.transactions order by id');
  assert.deepEqual(m.map((r) => r.id), ['tx2', 'tx3', 'tx4']);
  const tc = await as('tosve', 'select id from public.categories order by id');
  assert.deepEqual(tc.map((r) => r.id), ['c_h_groc', 'c_t_gas']);
  const ts = await as('tosve', 'select id from public.spaces order by id');
  assert.deepEqual(ts.map((r) => r.id), ['sp_house_1', 'sp_personal_t']);
});

test("cannot write into the partner's personal space", async () => {
  await rejects(as('tosve', `insert into public.categories (id, space_id, name, kind) values ('c_bad', 'sp_personal_m', 'X', 'expense')`), /row-level security/);
  await rejects(as('tosve', `insert into public.transactions (id, space_id, category_id, kind, amount, date, created_by)
    values ('txbad', 'sp_personal_m', 'c_m_beauty', 'expense', 1, '2026-11-01', $1)`, [ids.tosve]), /row-level security/);
  const upd = await as('tosve', "update public.transactions set amount = 1 where id = 'tx3' returning id");
  assert.equal(upd.length, 0, 'invisible rows cannot be updated');
  const after = await as('milica', "select amount from public.transactions where id = 'tx3'");
  assert.equal(Number(after[0].amount), 2500);
});

test('cannot move an entry into the partner\'s personal space', async () => {
  await rejects(as('tosve', "update public.transactions set space_id = 'sp_personal_m', category_id = 'c_m_beauty' where id = 'tx1'"), /row-level security|not in space/);
});

test('a stranger with an account sees nothing', async () => {
  for (const tbl of ['households', 'members', 'spaces', 'categories', 'transactions']) {
    assert.equal((await as('stranger', `select * from public.${tbl}`)).length, 0, tbl);
  }
  await rejects(as('stranger', `insert into public.categories (id, space_id, name, kind) values ('c_s', 'sp_house_1', 'X', 'expense')`), /row-level security/);
});

test('cannot pretend someone else added an entry, and the author never changes', async () => {
  await as('tosve', `insert into public.transactions (id, space_id, category_id, kind, amount, date, created_by)
    values ('tx5', 'sp_house_1', 'c_h_groc', 'expense', 100, '2026-11-23', $1)`, [ids.milica]);
  assert.equal((await as('milica', "select created_by from public.transactions where id = 'tx5'"))[0].created_by, ids.tosve, 'author is whoever is signed in');
  await as('tosve', "update public.transactions set created_by = $1, amount = 1900, updated_at = now() + interval '1 minute' where id = 'tx4'", [ids.tosve]);
  const [row] = await as('milica', "select created_by, amount from public.transactions where id = 'tx4'");
  assert.equal(row.created_by, ids.milica);
  assert.equal(Number(row.amount), 1900, 'Tosve may edit a House entry');
});

test("Milica can save Tosve's House entry the way phones do (insert-or-update), author stays Tosve", async () => {
  await as('milica', `insert into public.transactions (id, space_id, category_id, kind, amount, date, created_by, updated_at)
    values ('tx2', 'sp_house_1', 'c_h_groc', 'expense', 3300, '2026-11-21', $1, now() + interval '2 minutes')
    on conflict (id) do update set amount = excluded.amount, updated_at = excluded.updated_at, created_by = excluded.created_by`, [ids.tosve]);
  const [row] = await as('tosve', "select amount, created_by from public.transactions where id = 'tx2'");
  assert.equal(Number(row.amount), 3300);
  assert.equal(row.created_by, ids.tosve);
});

test('two phones edit the same entry: the newest edit wins, an older one is ignored', async () => {
  const [before] = await as('tosve', "select server_updated_at from public.transactions where id = 'tx2'");
  await as('tosve', "update public.transactions set amount = 4000, updated_at = now() + interval '1 hour' where id = 'tx2'");
  const stale = await as('milica', "update public.transactions set amount = 9999, updated_at = now() + interval '30 minutes' where id = 'tx2' returning id");
  assert.equal(stale.length, 0);
  const [row] = await as('milica', "select amount, server_updated_at from public.transactions where id = 'tx2'");
  assert.equal(Number(row.amount), 4000);
  assert.ok(row.server_updated_at > before.server_updated_at, 'server clock moved for pulling');
  // an upsert (what the phone sends) behaves the same
  await as('milica', `insert into public.transactions (id, space_id, category_id, kind, amount, date, created_by, updated_at)
    values ('tx2', 'sp_house_1', 'c_h_groc', 'expense', 7777, '2026-11-21', $1, now() + interval '10 minutes')
    on conflict (id) do update set amount = excluded.amount, updated_at = excluded.updated_at`, [ids.milica]);
  assert.equal(Number((await as('tosve', "select amount from public.transactions where id = 'tx2'"))[0].amount), 4000);
});

test('entries cannot be hard-deleted; they are marked deleted', async () => {
  const del = await as('tosve', "delete from public.transactions where id = 'tx1' returning id").catch((e) => e);
  assert.ok(del instanceof Error || del.length === 0);
  await as('tosve', "update public.transactions set deleted = true, updated_at = now() where id = 'tx1'");
  assert.equal((await as('tosve', "select deleted from public.transactions where id = 'tx1'"))[0].deleted, true);
});

test('an entry must use a category from its own space', async () => {
  await rejects(as('tosve', `insert into public.transactions (id, space_id, category_id, kind, amount, date, created_by)
    values ('tx6', 'sp_house_1', 'c_t_gas', 'expense', 100, '2026-11-23', $1)`, [ids.tosve]), /not in space/);
});

test('bad values are refused (negative amount, huge note, wrong kind)', async () => {
  const ins = (amount, kind, note) => as('tosve', `insert into public.transactions (id, space_id, category_id, kind, amount, date, created_by, note)
    values ('tx7', 'sp_house_1', 'c_h_groc', $2, $1, '2026-11-23', $3, $4)`, [amount, kind, ids.tosve, note]);
  await rejects(ins(-5, 'expense', ''), /check/);
  await rejects(ins(5, 'gift', ''), /check/);
  await rejects(ins(5, 'expense', 'x'.repeat(501)), /check/);
});

test('household: members can change currency but not the invite code; only rename yourself', async () => {
  await as('milica', "update public.households set currency = 'EUR', name = 'Doma'");
  await rejects(as('milica', "update public.households set invite_code = 'AAAAAAAA'"), /permission denied/);
  await as('tosve', "update public.members set display_name = 'Milica X' where user_id = $1", [ids.milica]);
  assert.equal((await as('milica', 'select display_name from public.members where user_id = $1', [ids.milica]))[0].display_name, 'Milica');
  await rejects(as('tosve', "insert into public.spaces (id, household_id, type, name, owner_id) select 'sp_hack', household_id, 'personal', 'x', $1 from public.members limit 1", [ids.stranger]), /permission denied/);
});

test('receipt photos: only for spaces you can see', async () => {
  const put = (user, name) => as(user, "insert into storage.objects (bucket_id, name, owner) values ('receipts', $1, $2)", [name, ids[user]]);
  await put('tosve', 'sp_personal_t/tx1.jpg');
  await put('milica', 'sp_house_1/tx4.jpg');
  await rejects(put('tosve', 'sp_personal_m/tx3.jpg'), /row-level security/);
  await rejects(put('stranger', 'sp_house_1/x.jpg'), /row-level security/);
  const seenByMilica = await as('milica', 'select name from storage.objects order by name');
  assert.deepEqual(seenByMilica.map((o) => o.name), ['sp_house_1/tx4.jpg']);
  const seenByTosve = await as('tosve', 'select name from storage.objects order by name');
  assert.deepEqual(seenByTosve.map((o) => o.name), ['sp_house_1/tx4.jpg', 'sp_personal_t/tx1.jpg']);
});

test('pulling changes: rows changed after a moment are found by server time', async () => {
  const [{ now }] = await as('tosve', 'select clock_timestamp() as now');
  await as('milica', "update public.categories set budget = 45000, updated_at = now() where id = 'c_h_groc'");
  const changed = await as('tosve', 'select id from public.categories where server_updated_at > $1', [now]);
  assert.deepEqual(changed.map((r) => r.id), ['c_h_groc']);
});
