# Budget for iPhone (native app)

The native iPhone version of the budget web app, so it is ready for a later App Store release.
It uses the **same data and the same free Supabase database** as the web app, so Tosve and
Milica can use either one and see the same House space.

## What's in it
- **Personal** (private, one each) and shared **House** space; month by month: what's left of the
  budget, spending per category, all entries; tap a category to see only its entries.
- Income and expenses per category in EUR; categories can be renamed, reordered, hidden, given a
  monthly budget, and you can add your own.
- **Receipts**: scan with Apple's document camera (straightens the photo). The text is read **on the
  phone** with Apple's free text reader (Vision); nothing is uploaded to read it. Items and the total
  (SKUPAJ / ZA PLAČILO) are filled in, and each item is compared with the last time you bought it.
- **Prices** tab: every item's price over time with a chart (grocery inflation).
- **Partner balance**: how much one sends the other so both have the same personal money.
- **Share with partner**: sign in with the same account as the web app; start a household or join
  with the partner's invite code. Works offline; syncs when there is a connection.
- **Backup**: save / restore a file that also works with the web app.
- **Ready for freemium**: free version = fewer categories, no own categories; full version = all.
  While testing everyone has the full version. The App Store purchase code is there but switched off.

## How it was tested
| What | How | Result |
|---|---|---|
| Budget logic (totals, months, hidden categories, reordering, backup, damaged files, full phone) | 19 tests incl. 2,000 random edits | pass |
| Same answers as the web app | The web app's own code was run on 4,000 generated receipts, 4,000 typed amounts, 3,000 item names and a 600-entry data file; the iPhone code must match every single answer | pass, 0 differences |
| Reading receipts | Sample Mercator/Lidl/Spar/Hofer/Tuš receipts; photos tilted up to 4° with shaky text positions | pass |
| Add/edit entry rules | Wrong amounts, missing category, bad dates, receipt totals, price comparison | pass |
| Syncing | Against a real Postgres database with the real privacy rules: two iPhones, conflicts both ways, deletes, offline, connection dropping mid-sync, photos, 2,500 entries, privacy (Milica can't see or write Tosve's Personal) | pass |
| iPhone ↔ web app | An iPhone and the web app's own sync code sharing one household: entries, edits, conflicts, deletes, categories and photos both ways end up identical | pass |
| Screens | 17 UI tests that tap through the app on an iPhone simulator (small and large iPhone) | written; need a Mac to run (see below) |

There is no Mac in the cloud workspace, so the screens (SwiftUI) could not be compiled or run
there. Everything else (all the logic and syncing) was compiled and tested on Linux with Swift 6.

## Running it
- **On a Mac (free):** `brew install xcodegen`, then `cd App && xcodegen && open Budget.xcodeproj`.
  Press ⌘U to run all tests, or pick your iPhone and press ▶︎ to install it. With a free Apple ID
  the app works for 7 days, then you press ▶︎ again.
- **On GitHub (free for public repositories):** `.github/workflows/ios.yml` (at the repository root)
  builds the app and runs every test on GitHub's Macs on each change to `ios/` or the web app's logic.
- **TestFlight / App Store:** needs the Apple Developer Program (99 USD a year). Not needed for testing.
- **Logic and sync tests on Linux** (from the repository root): `ios/scripts/start-test-backend.sh .` then
  `ios/scripts/test-linux.sh .` (needs Docker, PostgreSQL 16 and Node.js).

## Folders
- `Sources/BudgetKit/` all logic, no screens: data model (same JSON as the web app), money, budgets,
  receipt parsing, price history, sync (`SyncEngine`, `Supabase`), plans.
- `Tests/BudgetKitTests/` the tests above; `Fixtures/` holds the web app's answers (`scripts/make-golden.mjs`).
- `App/Budget/` the iPhone screens; `App/BudgetUITests/` the UI tests; `App/project.yml` the Xcode project.
- `scripts/` test helpers (test database, a "web app phone" for the cross tests).

If the web app's `store.js`, `receipt.js` or the database schema change, run
`node ios/scripts/make-golden.mjs .` and the tests again (the GitHub workflow does this on every run).
