# Sync design (Supabase), shared by the web app and the native iPhone app

The schema is in `supabase/migrations/20261125120000_budget_sync.sql`. That file is the source
of truth. This page explains how a client (web or native) is expected to use it.

## Accounts and pairing
- Sign-in uses **Supabase Auth with email and password**. In the dashboard turn off
  "Confirm email" while testing, and turn off "Allow new users to sign up" once both people
  have accounts.
- After the first sign-in, a person either:
  - calls `rpc('create_household', { display_name, house_space_id, personal_space_id })`. This
    creates the household, the House space and their Personal space, and returns the household row
    with `invite_code` (8 hex characters, upper case), or
  - calls `rpc('join_household', { code, display_name, personal_space_id })`. This adds them and
    creates their Personal space. There is a maximum of 2 members.
- Space ids are made by the client: `sp_house_<16 hex>` and `sp_personal_<16 hex>`, the same
  shape as `uid()` in store.js.
- If `members` has a row for `auth.uid()`, the user is already paired. Do not create again.

## Tables (cloud column, then local store.js field)
| table | columns |
|---|---|
| households | id uuid, name, currency (ISO 4217), invite_code, created_by, server_updated_at |
| members | household_id, user_id, display_name. Maps to `users[] {id: user_id, name: display_name}` |
| spaces | id, household_id, type `personal`/`house`, name, owner_id (null for house). Maps to `spaces[]` |
| categories | id, space_id, name, kind `expense`/`income`, budget (cents/month), sort_order, archived, deleted, updated_at, server_updated_at. Maps to `categories[] {id, spaceId, name, kind, budget, order, archived, updatedAt}` |
| transactions | id, space_id, category_id, kind, amount (cents, > 0), date (YYYY-MM-DD), note, items (JSON `[{name, price}]`, price in cents), receipt_path, created_by, created_at, updated_at, deleted, server_updated_at. Maps to `transactions[] {…, receiptId}` |

- Money is always an integer number of cents. Dates are plain `YYYY-MM-DD`.
- Ids are client-generated strings (`cat_…`, `tx_…`), so a phone can create rows offline.
- Timestamps come back as `2026-11-25T11:30:00.123456+00:00`. Trim to milliseconds before
  parsing; some Safari versions reject more than 3 decimals.

## Privacy (row level security)
- A Personal space and its categories, entries and photos are visible only to its owner.
- The House space is visible to and editable by both members.
- Signed-out (anon) requests can read nothing.
- `created_by` on a new entry is always set by the server to the signed-in user. It never
  changes on update.
- Rows cannot be hard-deleted. To delete, set `deleted = true` (a "tombstone") so the other phone learns about it.
- All of this is enforced by the database. A client cannot get around it.

## Sync algorithm (what sync.js does)
1. **Local first.** The phone keeps its full copy and works offline. Every local change records
   the row id as "dirty". A deleted entry keeps a tombstone copy until it is uploaded.
2. **Push:** upload receipt photos first, then upsert dirty categories, then dirty transactions
   (`upsert(rows, { onConflict: 'id' }).select('id')`), in chunks of 200.
3. **Conflicts: last write wins** on `updated_at` (the client's edit time). The server silently
   ignores an update whose `updated_at` is older than the stored one. Such rows are missing
   from the upsert's returned ids. The client then re-fetches those ids and takes the server
   version.
4. **Pull:** for each table, `select * where server_updated_at > lastPull - 15s order by
   server_updated_at, id`, in pages of 1000 (`range`). Remember the highest `server_updated_at`
   seen. `server_updated_at` is the server clock, so phone clock differences don't lose rows.
5. **Merge:** for each pulled row, keep the local row if it is dirty and newer. Otherwise take
   the server row. A row with `deleted = true` is removed locally.
6. **When it runs:** after a local change (1.2 s debounce), when the app comes to the foreground,
   when the connection returns, and every 30 s while the app is open.

## First sign-in on a phone that already has data
The phone's Personal space is moved into the user's cloud Personal space. Its House data merges
into the cloud House. Categories with the same name and kind are merged into one, and entries
are re-pointed to them. Entries made before sign-in carry the placeholder author `u_…` and get
the signed-in user as author. Rows already in the cloud (same id) are not duplicated; the newer
`updated_at` wins.

## Receipt photos
- Supabase Storage bucket `receipts` (private, 3 MB max, JPEG only).
- Path: `<space_id>/<transaction_id>.jpg`. The transaction's `receipt_path` holds that path.
- Access follows the space: House photos are visible to both, Personal photos only to the owner.
- The web app stores photos as about 1600 px JPEGs of 200–400 KB, so the free 1 GB is roughly
  3,000 receipts.

## Free-tier notes
- Supabase free plan: 500 MB database, 1 GB file storage, no credit card. It cannot bill you
  unless you upgrade.
- A free project is **paused after 7 days with no activity**. Opening the app counts as activity.
  A paused project is restored from the dashboard with one click, and no data is lost.

## Testing
- `tests/backend/rls.test.cjs`: privacy rules against a real Postgres (19 checks).
- `tests/backend/sync.test.mjs`: two simulated phones syncing with supabase-js (19 checks).
- `tests/e2e-sync.cjs`: two iPhone-sized browsers using the real app screens (14 checks).
- `tests/backend/fake-supabase.cjs`: a local stand-in for Supabase that runs requests on
  Postgres as the signed-in user. Use it for offline testing only. Point `SUPABASE_URL` and
  `SUPABASE_ANON_KEY` at the real project for the final check.
