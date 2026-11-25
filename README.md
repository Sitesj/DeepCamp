# Deer Camp

Deer Camp is a phone app for a small hunting group. Each hunter picks their name and stand, then taps big buttons to record **deer sightings** and **gunshots heard**. Records are saved on the phone first and upload to the camp's shared database when there is cell service. Everyone can then see the activity on a satellite map, look at a deer heat map, replay a hunt minute by minute, and download or import the records as JSON.

**Design rule: RECORD FIRST, SYNCHRONIZE SECOND.** A sighting is never lost because there was no signal.

- No property names, property IDs or boundaries. Only **hunters** and **stands** (each stand has GPS coordinates).
- Works without cell service once it has been opened one time with internet.
- Plain HTML, CSS and JavaScript, hosted on GitHub Pages. Data is stored in Supabase (PostgreSQL + Auth + Row Level Security).

---

## Contents

1. [Create the Supabase project](#1-create-the-supabase-project)
2. [Apply the database migration](#2-apply-the-database-migration)
3. [Configure authentication](#3-configure-authentication)
4. [Configure the public Supabase connection](#4-configure-the-public-supabase-connection)
5. [Add hunters](#5-add-hunters)
6. [Add stands and GPS coordinates](#6-add-stands-and-gps-coordinates)
7. [Deploy to GitHub Pages](#7-deploy-to-github-pages)
8. [Install on a phone](#8-install-on-a-phone)
9. [Test offline recording](#9-test-offline-recording)
10. [Test synchronization](#10-test-synchronization)
11. [Export JSON](#11-export-json)
12. [Import JSON](#12-import-json)
13. [Use Hunt Replay](#13-use-hunt-replay)
- [Using Deer Camp in the stand](#using-deer-camp-in-the-stand)
- [Phone-only mode (no Supabase)](#phone-only-mode-no-supabase)
- [Project layout](#project-layout)
- [Automated tests](#automated-tests)
- [Known limitations](#known-limitations)

---

## 1. Create the Supabase project

1. Go to <https://supabase.com>, sign in, and click **New project**.
2. Pick a name (for example `deer-camp`), set a strong database password (keep it private, it is **not** used by the app), and pick the region closest to camp.
3. Wait for the project to finish setting up.

## 2. Apply the database migration

The schema is in [`supabase/migrations/`](supabase/migrations/), as four files that run **in order**:

1. `20261122000001_deer_camp_schema.sql` — the tables, security and triggers
2. `20261122000002_mixed_deer_groups.sql` — buck / doe / fawn / unknown counts, so one sighting can be a mixed group
3. `20261125000003_camp_code_sign_in.sql` — sign-in with a camp code instead of e-mail
4. `20261125000004_admin_pin.sql` — a separate admin PIN for joining as an administrator
5. `20261126000005_stand_colors_and_clearing.sql` — stand colors, and clearing old camp records

For a **new project**, [`supabase/setup-all-in-one.sql`](supabase/setup-all-in-one.sql) is all the files joined together, so you only paste once.
If your project **already ran the first file**, use [`supabase/upgrade-existing-project.sql`](supabase/upgrade-existing-project.sql) instead (files 2 onward joined; safe to run again if some or all of it was run before).

Together they create:

| Table | Purpose |
|---|---|
| `profiles` | One row per hunter: display name, administrator flag, active flag |
| `hunter_devices` | Which phone is signed in as which hunter (supporting table; one phone per hunter name) |
| `camp_settings` | The camp code and the admin PIN, each stored only as a bcrypt hash (supporting table) |
| `join_attempts` | Wrong camp-code tries per phone, for the lock-out (supporting table) |
| `stands` | Stand name, latitude, longitude, description, active flag |
| `hunting_sessions` | Start / end of each hunt (hunter + stand) |
| `deer_sightings` | Every deer sighting with direction, distance range, heading, number of bucks / does / fawns / unknown (one sighting can be a mixed group), total, weather |
| `gunshot_reports` | Every gunshot heard with direction and bearing |

It also turns on Row Level Security, adds the policies, check constraints, indexes, triggers and Realtime publication.

**Option A — SQL Editor (easiest):** open your project → **SQL Editor** → **New query**, paste all of `setup-all-in-one.sql`, click **Run**. It should finish with "Success. No rows returned". (If you already ran earlier files, run only the ones you have not run yet, in order.)

**Option B — Supabase CLI:**

```bash
supabase link --project-ref YOUR-PROJECT-REF
supabase db push
```

### What the database enforces

- A phone sees nothing until it has **joined the camp**: entered the right camp code and picked an active hunter name.
- The camp code is checked on the server and stored only as a hash. After 5 wrong tries a phone is locked out for 15 minutes.
- Joining as a name marked **administrator** also needs the separate **admin PIN** (also hashed, and it must differ from the camp code). Wrong admin PINs count toward the same lock-out.
- A hunter name can be in use on **one phone at a time**. Nobody else can pick that name, even with the camp code, until the hunter switches off it or the administrator releases it.
- A phone can only create sessions, sightings and gunshot reports **as the hunter it joined as**. Choosing a different name in the app cannot post as someone else.
- Sightings and gunshots can only be attached to the hunter's **own** hunting session.
- Original observations can never be edited. The only change allowed is **voiding** your own record (with a reason). A voided record cannot be un-voided. Corrections are new records that point back to the voided one (`corrects_id`).
- Only administrators can add or change stands and hunters, release phones and change the camp code. Stands and hunters are deactivated, never deleted. The last administrator cannot be removed.
- Records are uploaded with the UUID made on the phone, so uploading the same record twice never creates a duplicate.

## 3. Configure sign-in and set the camp code

Hunters do **not** need an e-mail address. Each phone gets its own private Supabase account automatically ("anonymous sign-in") the first time it joins, and stays signed in.

In the Supabase dashboard:

1. **Authentication → Sign In / Providers**: turn **on** "Allow anonymous sign-ins". (Without this the app shows "Camp sign-in is not turned on yet".)
2. Leave the default session settings. Phones stay signed in and refresh automatically whenever they have service.

**Add yourself as the first hunter and administrator, and set the camp code and the admin PIN.** In the **SQL Editor**, run (with your own name, a camp code for everyone, and a *different* admin PIN for you — each at least 6 digits):

```sql
insert into public.profiles (display_name, is_admin, is_active) values ('Your Name', true, true);
select public.set_camp_code('123456');
select public.set_admin_pin('654321');
```

Then open the app, type the camp code, tap your name, and enter the admin PIN.

## 4. Configure the public Supabase connection

In **Project Settings → API Keys**, copy:

- the **Project URL** (looks like `https://abcd1234.supabase.co`)
- the **Publishable key** (`sb_publishable_...`) — or the legacy **anon public** key

Put them in [`config.js`](config.js):

```js
window.DEER_CAMP_CONFIG = {
  supabaseUrl: 'https://abcd1234.supabase.co',
  supabaseKey: 'sb_publishable_xxxxxxxxxxxxxxxx'
};
```

These two values are meant to be public: security comes from Row Level Security in the database. **Never** put the `service_role` / secret key in `config.js`, in the app, or in the repository. (The app refuses keys that look like secret keys.)

You can also enter the URL and key on a single phone in **Settings → Connection setup**, which is handy for trying things out before editing `config.js`.

## 5. Add hunters

As an administrator, open **☰ → Settings → Hunters**:

1. Under **Add a hunter**, type the hunter's name and tap **ADD HUNTER**. Tick *Camp administrator* if they should manage stands and hunters too.
2. Give the hunter the **camp code**. They open Deer Camp, type the code, and tap their name. That's all — no e-mail or password.

Also in Settings → Hunters you can:

- **RENAME** a hunter or **DEACTIVATE** them (they are signed out everywhere; their past records are kept), and **ACTIVATE** them again.
- **RELEASE PHONE** when a hunter gets a new phone or loses one: their name becomes free to join on another phone. Nothing is deleted; anything still waiting on the old phone uploads if that phone joins again as the same hunter.
- **MAKE ADMIN / REMOVE ADMIN**.
- **CHANGE CAMP CODE**. Hunters already joined stay joined; only new joins need the new code.
- **CHANGE ADMIN PIN**. Needed to join as any administrator; give it only to administrators. When you make someone an administrator who has not joined yet, they will need it to join.

**Switch hunter** (Settings) frees the name on this phone, so a phone can be handed to another hunter. Records not yet uploaded stay on the phone and upload when their hunter joins on it again; they are never uploaded under someone else's name.

## 6. Add stands and GPS coordinates

As an administrator, open **☰ → Settings → Stands → ADD STAND** (or **EDIT** on an existing stand):

- **Stand name** — what hunters will see, e.g. "North Ridge".
- **Latitude / Longitude** in decimal degrees, e.g. `38.12345` and `-90.12345`. You can paste `38.12345, -90.12345` (as copied from Google Maps) into the Latitude box.
- **Color** — each stand has its own color, used for its map marker and for its BANG! in Hunt Replay. A new stand gets an unused color automatically; tap a different circle to change it.
- **📍 USE MY CURRENT LOCATION** fills in the coordinates from the phone's GPS — easiest when you are standing at the stand.
- If the spot is far from your other stands, Deer Camp warns you before saving. The usual cause is a missing minus sign: in the U.S. the longitude is negative (for example `-90.12345`); without the minus sign the stand lands in Asia.
- **Active** — untick to hide a stand you no longer hunt. Old records keep their location because each record stores the stand's coordinates at the time it was made.

Changing stands needs an internet connection. Every phone picks up the new list the next time it syncs.

## 7. Deploy to GitHub Pages

The repository includes [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml). On every push to `main` it runs the unit, database and browser tests, then publishes the site.

1. Merge this work into `main`.
2. In GitHub: **Settings → Pages → Build and deployment → Source: GitHub Actions**.
3. Push to `main` (or run the workflow from the **Actions** tab). When it finishes, the site is at `https://YOUR-USER.github.io/DeepCamp/`.

The workflow stamps the commit id into `sw.js`, so phones get the new version automatically. They see a green **"A new version of Deer Camp is ready — UPDATE NOW"** bar; the update never interrupts an entry in progress and never touches saved records.

*Deploying from a branch instead* (Settings → Pages → Deploy from a branch → root) also works because all paths are relative. In that case change `VERSION` in `sw.js` by hand for every release, otherwise phones keep the old cached version.

## 8. Install on a phone

Open the site **once with internet** so the app can save itself on the phone.

- **iPhone (Safari):** tap the Share button → **Add to Home Screen** → Add. Always open Deer Camp from the home-screen icon. (Installing also protects the saved records from Safari's automatic cleanup of website data.)
- **Android (Chrome):** tap ⋮ → **Install app** (or **Add to Home screen**).

Then join with the camp code, choose your stand, and check **☰ → Settings → About this phone**: it should say *App files: ready for offline use*. If it does not, close the app and open it again while you have service.

## 9. Test offline recording

1. With service, open Deer Camp, join with the camp code, choose a stand.
2. Turn on **Airplane mode**.
3. Close Deer Camp completely, then open it again from the home-screen icon. It should open normally and show **Offline (no service)**.
4. Tap **LOG DEER SIGHTING** and go through the steps. You should see **SAVED ON PHONE — WILL SYNC LATER**.
5. The top bar shows **⏳ Waiting to Sync (1)**. Close and reopen the app: the record is still there (**☰ → Camp Activity**, marked *Waiting to Sync*).

The satellite pictures do not load offline; the maps still show stands and records over a plain background.

## 10. Test synchronization

1. After the offline test, turn Airplane mode **off**.
2. Within a few seconds the top bar changes to **⟳ Syncing…** and then **✓ Synced**. You can also tap the sync status to sync right away.
3. On a second phone joined as another hunter, open **Camp Activity** or **Live Map**: the record appears with the original time it was seen (not the upload time).
4. In Supabase → **Table Editor → deer_sightings** you can see the row. Syncing again never creates a second copy.

Sync is attempted when the app starts, when service comes back, when the app is brought to the front, every minute or two while it is open, after every new record, and when you tap the status. Failed uploads are retried automatically and shown as **Sync Failed — tap to retry** with the reason in Settings → Sync.

### Clearing old records

- **Every hunter — Settings → Clear records from this phone:** removes records up to and including a date (it starts on today, so one tap clears everything) from that phone only, to keep it tidy. The camp keeps its copy, anything still waiting to upload is never removed, and cleared records are not downloaded again (a link in the same card downloads them again if wanted). In phone-only mode the phone holds the only copy, so cleared records are gone for good.
- **Administrator — Settings → Clear old camp records:** permanently deletes deer sightings, gunshot reports and empty hunts up to and including a date **for everyone**. The app offers to download a backup first. Every phone removes its copies the next time it syncs. A record still waiting to upload on some phone when the camp is cleared will still upload afterwards.

## 11. Export JSON

**☰ → Settings → Download hunt JSON**. Choose:

- **One hunt** (a single hunting session),
- **One day**,
- **Date range**, or
- **Everything**,

then tap **DOWNLOAD HUNT JSON** (or **SHARE HUNT JSON** to send it by text/e-mail on phones that support it).

The file contains the schema version, export time, hunter names, stand names/IDs/coordinates, hunting sessions, deer sightings and gunshot reports with their original UUIDs, timestamps, bearings, distance ranges, quantities, types and weather. Voided records are included and marked `"status": "voided"`. There is no property information. The file contains everything needed to replay the hunt without Supabase.

## 12. Import JSON

**☰ → Settings → IMPORT HUNT JSON**, then pick a Deer Camp JSON file.

- The file is checked first. Files that are not Deer Camp exports are rejected; individual invalid records are skipped and listed.
- Imported hunts go into a **separate replay list**. They are never uploaded to Supabase and never mixed into the camp records.
- Importing the same file again adds nothing new (events are matched by their UUID).
- **REMOVE IMPORTED DATA** clears the imported list from this phone only.

Imported hunts can be replayed offline.

## 13. Use Hunt Replay

**☰ → Hunt Replay**

1. Choose **Camp records** or **Imported files**, the **date**, the **Morning hunt** (midnight–noon), **Evening hunt** (noon–midnight) or **Whole day**, and **All stands** or one stand. Replay opens on the latest hunt of the day that has activity.
2. Tap **▶ PLAY**. The clock runs from just before the first event of the day to just after the last. Choose the speed (1x, 5x, 10x, 30x, 60x, 300x). **NEXT ⏭** jumps to the next event; drag the timeline to move anywhere; **⟲ RESTART** goes back to the start.
3. **Deer** appear at their *estimated* first-seen location (stand + reported direction + middle of the distance range) with a short arrow showing the direction they were headed. No path is drawn: Deer Camp only knows where a deer was first seen and which way it was going.
4. **Gunshots** show a big red **!** above the stand that heard it and a **BANG!** placed toward the edge of the map in the direction the sound came from, with that direction written on it (for example "NW"). The BANG! is the **color of the stand** that heard it. These stay on the map for **30 seconds (real time)** and then fade away; the gunshot stays in the event list. The arrow is a direction only, never the location of the shot. If several hunters heard the same shot, each report is shown separately.
5. Tap any event in the list below the map to jump to it. Use **Deer**, **Gunshots** and **Show stands** to hide or show things.

Events always appear at the time the hunter reported them, never the time they were uploaded.

---

## Live Map and Deer Heat Map

- The **Live Map** fills the screen and opens on the hunt you are in: **This morning** before noon, **This evening** after.
- Each stand shows **one 🦌 bubble** with the number of deer reported there. **Tap a bubble** to see that stand's sightings one by one, each with a short arrow showing the way the deer was headed. **SHOW ALL STANDS** goes back. No pinching or zooming is needed.
- Gunshots show as **one 💥 badge per stand** in the stand's color, with the count and the directions heard (for example "💥 2 · NW, E"). Tap it for the times.
- **FILTERS** opens one page of big buttons: when (This morning, This evening, Today, Last 7 days, All), which stand, which deer, gunshots on/off, distance ranges, and the map key. A line next to the button always says what is shown.
- The **Deer Heat Map** uses the same FILTERS page (plus chosen dates).

## Using Deer Camp in the stand

- **START HUNT** when you get in the stand, **END HUNT** when you leave. (If you forget, logging a sighting starts a hunt automatically.) Hunts with no sightings are kept too — they show how much time was spent hunting.
- **LOG DEER SIGHTING** (5 steps, the time is taken when you tap the button):
  1. Tap the circle on the compass where you **first saw** the deer (north is always at the top).
  2. Tap **how far** away: 0–25, 25–50, 50–75, 75–100 or 100–200 yards.
  3. Tap the direction the deer was **headed**, or **NOT SURE**.
  4. **How many of each?** Pick a number from the dropdown next to **BUCKS**, **DOES**, **FAWNS** and **UNKNOWN** — for example 3 does, 1 buck and 2 fawns in one sighting.
  5. Check the summary and tap **RECORD SIGHTING**.
- **GUNSHOT HEARD**: tap it right away (the time is taken then), then tap the compass circle the shot came **from**. That's it.
- **Mistakes:** tap **UNDO** on the confirmation screen, or **UNDO** under "Your last entry" on the home screen, or **FIX** in Camp Activity. You can re-enter it correctly (the original time is kept) or void it. Nothing is ever erased: the original stays in the history marked *voided*.
- The top bar always shows **Online/Offline** and the sync status: *Saved on Phone*, *Waiting to Sync*, *Syncing*, *Synced*, *Sync Failed*.
- **Extra-large text** can be turned on in Settings.

## Phone-only mode (no Supabase)

If `config.js` is left empty, Deer Camp runs on a single phone with no sign-in: add hunter names and stands in the app, record, view the maps, replay, and export JSON. Nothing is shared or uploaded. Records made in phone-only mode stay on that phone (export them as JSON to keep them) and are not uploaded if a Supabase connection is set up later.

## Project layout

```
index.html                     The whole app: screens, styles and logic (no build step)
js/core.js                     Pure logic shared with the tests: compass, geodesy, validation, export/import
config.js                      Public Supabase URL + publishable key (edit this)
sw.js                          Service worker: caches the app for offline use
manifest.webmanifest           Install-to-home-screen settings
icons/                         App icons
vendor/                        Leaflet 1.9.4, Leaflet.heat 0.2.0, supabase-js 2.x (local copies so they work offline)
supabase/migrations/           Database schema, Row Level Security, triggers
tests/core.test.js             Unit tests (node --test)
tests/db/                      Database schema + RLS tests on plain PostgreSQL
tests/e2e/                     Browser tests (Playwright) with an in-memory fake Supabase
.github/workflows/deploy.yml   Test + deploy to GitHub Pages
```

How it fits together:

- **Saving:** every record gets a UUID and its original timestamp on the phone, then is written to IndexedDB in one transaction together with an upload-queue ("outbox") entry, and read back before **SAVED** is shown. If the write fails the hunter sees **NOT SAVED** instead.
- **Uploading:** the outbox is uploaded with `upsert` by UUID (sessions first, then observations). A record is marked synced only after Supabase returns it. Records belonging to a different hunter than the one this phone has joined as stay queued until that hunter joins on this phone again — they are never re-attributed.
- **Downloading:** shared records are pulled incrementally by `updated_at` (plus Supabase Realtime when available). A download never overwrites a local change that is still waiting to upload.
- **Location estimate:** destination point on a sphere (mean Earth radius) from the stand, the 16-point bearing (22.5° steps, N = 0°) and the middle of the distance range in yards × 0.9144. The map can also show the uncertainty sector (±11.25°, min–max distance). The original direction and distance range are always stored; the coordinates are an approximate derived value.
- **Weather:** Open-Meteo values for the stand's coordinates are cached on the phone and attached to each record from the cache, so weather never delays recording. Each snapshot stores the source, the weather time, the retrieval time, and whether it is `forecast` (fresh model data) or `cached` (older than an hour). Missing values stay empty.
- **Maps:** Esri World Imagery (with optional labels) and OpenStreetMap as an alternative layer, with attribution shown on the map. Tiles are not stored for offline use.

## Automated tests

```bash
# Unit tests (compass, geodesy, validation, export/import, weather selection)
node --test tests/*.test.js

# Database schema, constraints, triggers and Row Level Security on PostgreSQL 16
# (uses a small stub of Supabase's auth schema; needs a local PostgreSQL)
PGHOST=localhost PGUSER=postgres bash tests/db/run.sh

# Browser tests in a phone-sized Chromium (needs the `playwright` package and Chromium)
node tests/e2e/run.js
SCREENSHOTS=./screenshots node tests/e2e/run.js   # also saves screenshots
```

The browser tests cover the required scenarios against an in-memory **fake Supabase** (`tests/e2e/fake-supabase.js`) that mimics sign-in, upsert-by-id and the "only your own records" rule:

| Test | What is checked |
|---|---|
| A | Wrong camp code refused; join with the camp code, choose stand, start hunt, record a sighting → saved locally with all fields, weather attached, uploaded with the same UUID and original time, marked Synced |
| B + I | Offline: record, close the app, reopen it with no connection (served by the service worker), record is still there and pending |
| C | Several offline records sync after reconnecting, including a case where the server saved a record but the reply was lost — no duplicates |
| D | Gunshot saved with correct stand, tap-time timestamp and bearing (NW = 315°) |
| E / E2 | A name in use on one phone cannot be picked on another; two hunters at different stands see each other's records; on a shared phone one hunter's queued records are never uploaded under another hunter |
| F | Replay is chronological across stands; deer placed at the right bearing and distance; travel arrows; red **!**; dashed gunshot arrows pointing the right way to the map edge; **BANG!** appears; gunshot markings disappear after 30 seconds while deer stay |
| G | Export → import keeps UUIDs, timestamps and bearings; re-import adds nothing; imports are not uploaded; bad files are rejected; imported hunt replays offline |
| H | At 320, 360 and 414 px wide: exactly 16 circular compass buttons, all visible, ≥ 44 px, not overlapping, north on top, no duplicate buttons or dropdowns, tapping a circle advances |
| Others | Mixed groups (3 does, 1 buck, 2 fawns); voiding keeps the original record; 5 wrong camp codes lock a phone out; admin adds a hunter, releases a phone and changes the code; a released phone is asked to join again; clear message when anonymous sign-in is off in Supabase; phone-only mode works; no JavaScript errors |

The database tests check, on real PostgreSQL, that hunters cannot write records as someone else, cannot attach records to another hunter's session, cannot edit original observations or un-void them, that inactive and anonymous users see nothing, that only admins manage stands/hunters, that invites activate accounts, that duplicate uploads are idempotent, and that no property tables or columns exist.

**Not covered by automated tests:** a live Supabase project (real anonymous sign-in, Realtime), real iPhone/Android devices, and real satellite tiles. Do steps 9 and 10 above on real phones after setting up your project.

## Known limitations

- **Joining the camp needs internet** the first time on each phone. After that, the app opens and records with no service.
- **The camp code is shared.** Anyone who has it can join as a hunter name that is not yet in use on a phone. Add only the names you want, change the code if it gets out, and release or deactivate names you do not recognize.
- If a phone is reset or Deer Camp's data is cleared, that phone loses its sign-in; the administrator releases the hunter's name so they can join again.
- **iPhone:** there is no background sync on iOS, so uploads happen while Deer Camp is open (on start, when service returns, when it comes to the front, and periodically). Open the app once you have service to upload. Install it to the home screen so iOS does not clear its saved data.
- **Satellite imagery needs internet.** Offline, maps show stands and records over a plain background. Tiles are deliberately not saved for offline use (imagery licence terms).
- **Weather** comes from Open-Meteo's weather models for the stand location (not a weather station). If there was never service at a stand, records there have no weather.
- **Administrator tasks** (hunters, stands) need internet.
- **Location estimates are approximate.** They come from a compass direction (±11.25°) and a distance range. The heat map shows where deer were *reported*, not how many deer there are; two hunters may report the same deer, and several gunshot reports may be the same shot. Deer Camp never merges reports.
- **Dates** are grouped by the phone's own time zone. Timestamps are stored in UTC.
- **Editing `config.js`** after phones have installed the app requires a new deployment (so the service worker picks it up), or entering the values in Settings → Connection setup.
- Records made in **phone-only mode** cannot later be uploaded to Supabase. Once the phone joins a camp they are hidden from the camp's maps, feed and replay, and **Settings → Records from phone-only testing** lets you download them as JSON or remove them.
