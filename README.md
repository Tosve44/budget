# Budget

A small budget app for two people (Tosve and Milica), made as a web app that can be
added to the iPhone home screen.

- **Personal**: one private space per person. **House**: a shared space.
- Monthly budget per category, income and expenses, monthly overview.
- **Receipts**: take a photo of a bill; the items and prices are read on the phone
  (Tesseract, open source, nothing is uploaded) and each item is compared with the last
  time it was bought. The **Prices** tab shows every item's price history.
- Works offline. Data is stored on the phone (localStorage + IndexedDB for photos).
  Settings > Backup downloads all data as one JSON file (photos are not included).

## Files
- `index.html`, `styles.css`, `app.js`: screens
- `store.js`: data model (one plain JSON object, documented at the top of the file)
- `photos.js`: receipt photo storage
- `receipt.js`: reading a receipt photo and finding item lines
- `sync.js`, `cloud.js`, `config.js`: syncing with Supabase (see SYNC.md); `config.js` holds the project URL and public key
- `supabase/migrations/`: the cloud database tables and privacy rules
- `sw.js`, `manifest.webmanifest`, `icons/`: offline support and home screen install
- `vendor/tesseract/`: the on-phone text reader (Apache-2.0) and language data (English, Slovenian, Serbian)

## Run it locally
Any static file server, for example `python3 -m http.server 8000`, then open http://localhost:8000.
No build step.

## Syncing between phones
See [SYNC.md](SYNC.md). Without a Supabase project in `config.js` the app works on one phone only.

## Tests
Backend tests need a local Postgres 16 and `npm i pg @supabase/supabase-js` somewhere on NODE_PATH:
- `node --test tests/backend/rls.test.cjs`: privacy rules (after loading `tests/backend/supabase-base.sql` and the migration).
- `node tests/backend/fake-supabase.cjs &` then `node --test tests/backend/sync.test.mjs` and `node tests/e2e-sync.cjs`: two phones syncing.

- `node --test tests/logic.test.mjs`: money parsing, budgets and totals, price comparison, backup/restore, receipt text parsing.
- `python3 -m http.server 8123 & node tests/e2e.cjs`: click-through tests on iPhone SE, 13 and 14 Pro Max screen sizes
  (Chromium with iPhone emulation), including reading the sample receipt photos in `tests/`.
