# Hololoco

Hololoco puts offers, 3D objects and messages at real places. This website is where businesses sign in to place and manage them. People find them in the Hololoco phone app, a separate Unity app still to come, which reads the same Supabase database and accounts.

This repository is the website at hololoco.com. It replaces the 2021 portal and Android app completely and shares no code or data with them.

## Status

The website became the business side on 2026-11-14: the start page asks people to sign in, and the public browsing (type filters, the nearby list, drop pages, View in AR) moved to the app. Next come offers with quest tiers and an automatic AI review, then a quest builder; see the design doc's "Quests" section.

Phase 3, safety, has started: the review queue, reports, and photo and 3D model uploads are built. Rules on where drops can go and the legal pages have moved later in the plan. Phase 2, adding to the map, is built and waiting on its gate: sign-in at Publish (an emailed code or link, and Google once it's switched on), the three-step add flow with ready-made objects, schedules, and Your drops with edit, pause and delete. The database enforces the rules. Phase 1's gate, a test on a mid-range phone, is still open too. Offers, uploads, reports and the review queue come in later phases.

| Phase | Delivers | Gate to move on |
| --- | --- | --- |
| 0. Set up | Accounts, this repository, the empty app | Empty app deploys |
| 1. The map | 3D map, search, filters, pins, drop page, with sample content | Runs smoothly on a mid-range phone with 3D models showing |
| 2. Adding to the map | Sign-in, add flow, ready-made objects, schedules, your drops | Five new people publish a drop without help |
| 3. Safety | Uploads, review queue, reports, placement rules, legal pages | Permission tests pass; a lawyer has reviewed the terms |
| 4. Offers | Business verification, offers, claims, redeeming in store | A real business runs one offer; simultaneous claims never oversell |
| 5. Open in one city | Invited creators first, then the public | Reports handled within 24 hours for four weeks |

## Run it

Needs Node 20.9 or later.

```sh
npm install
npm run dev
```

Then open http://localhost:3000. `npm run lint` and `npm run build` should both pass before every push.

The map needs a Mapbox public token: copy `.env.example` to `.env.local` and set `NEXT_PUBLIC_MAPBOX_TOKEN`. Without it the panel still works and says the map couldn't load. Without the Supabase settings the site runs on sample drops only and sign-in is off. Never commit real values.

If a change to `app/globals.css` doesn't show up, stop `npm run dev`, delete `.next/dev` (Turbopack's dev cache can keep the old stylesheet), and start it again.

### Setting up Supabase

Once per project, in Hololoco's own Supabase project:

1. Run each file in `supabase/migrations/` in order (SQL editor or `supabase db push`), then run `supabase/tests/permissions.sql` as one query. It creates throwaway test accounts, checks every rule, deletes them again, and lists the results; every row should say `passed: true`.
2. Put the project URL and publishable key in `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, in `.env.local` and in Vercel.
3. Authentication → URL Configuration: set the Site URL to the live site, and add `http://localhost:3000/**` and the live site's `/**` to the redirect URLs.
4. Authentication → Emails: in the Magic Link and Confirm signup templates, give people the code and a link that works across browsers:

   ```html
   <p>Your Hololoco sign-in code is <b>{{ .Token }}</b>.</p>
   <p>Or <a href="{{ .SiteURL }}/auth/confirm?token_hash={{ .TokenHash }}&type=email">sign in on this device</a>.</p>
   ```
5. Email delivery: Supabase's built-in email only reaches members of the Supabase team. For anyone else, set up custom SMTP (Authentication → Emails → SMTP), or rely on Google.
6. Google (optional): create a Web OAuth client in Google Cloud with the redirect URI `https://<project-ref>.supabase.co/auth/v1/callback`, add it under Authentication → Providers → Google, then set `NEXT_PUBLIC_GOOGLE_SIGN_IN=on`.

Staff review drops at `/review` and skip review and limits themselves. Make someone staff in the SQL editor: `update public.profiles set is_staff = true where id = '<user id>';`.

### Ready-made objects

The library in `public/library/` is generated, not drawn by hand:

```sh
node scripts/library/build-models.mjs       # GLB files, 1 m across, from simple shapes
node scripts/library/render-thumbnails.mjs  # PNG thumbnails, rendered with headless Chrome
```

Then list any new object in `lib/library/objects.ts`, and add it to the `library_objects` table with a migration (drops can only use objects in that table).

## Stack

| Layer | Choice |
| --- | --- |
| App | Next.js 16 (App Router, Cache Components), TypeScript, Tailwind CSS 4 |
| Hosting | Vercel |
| Data and sign-in | Supabase: Postgres with PostGIS, Auth, Storage |
| Map | Mapbox GL JS, Standard style (faded theme), behind `lib/map/engine.ts` |
| 3D models | GLB only, drawn by Mapbox's own model layer; three.js builds the library and processes uploads |
| Place search | Mapbox Geocoding API v6 (addresses and places, not businesses) |

## How the map works

- The map is the signed-in person's workspace. Their own drops show in every state (in review, live, paused, not approved), each as a pin (a real button, so it works with a keyboard) and, from zoom 15.5 in, its 3D model at its place, height and turn. The pin stands on top of the model. Clicking one opens it for editing.
- Other people's public drops nearby show as small, dimmed pins without their models, so people can see what's around when placing theirs. They can't be clicked. Signed out, the map shows no drops.
- Models are drawn larger than life so they can be seen from a block away: twice their size plus 12 m (a 6 m object shows as 24 m). The drop keeps its true size for AR in the app.
- The person's own drops come from `my_drops`, with signed links for uploads that aren't public yet. Other people's come from `public_drops_in_bounds` through `lib/drops/source.ts`, plus the sample set in `lib/drops/sample.ts`. To move the samples, change `SAMPLE_CENTRE`.
- A person's location is only used in the browser, when they press "Show my location". Place search sends Mapbox the typed words and the centre of the map being viewed.

## How adding works

- The start page asks people to sign in with Google or an emailed code. The email has a code to type, which keeps them in the same tab, and a link. The add flow's draft is saved in the browser as they go, so someone who starts it signed out can still sign in at Publish without losing it.
- Publishing calls `save_drop` straight from the browser. The database decides everything: who owns what, the limits (10 drops at a time, 5 new a day, 20 public drops within 100 m, 30 m size, 100 m height), and review. Each account's drops stay in review until one has been approved. Its errors are short codes that `lib/drops/mine.ts` turns into plain words.
- Visitors can't read any table. Public drops come only from the `public_*` functions, which return approved, unpaused drops (and only those within their hours, for the map).
- Property owners can ask for a removal at `/report`, with no account. The app will file reports through the same `file_report` function. A serious report (danger, or someone's personal information) hides the drop at once, and so do reports from three different people within a week; it goes back to review. Ten reports a day per person. People without an account are told apart by a keyed hash of their connection that changes weekly; their address isn't stored. Only staff can read reports.
- Staff work through reports and the queue at `/review`: approve, or don't approve with a reason the owner sees in Your drops. Editing a drop that wasn't approved sends it back to the queue. Every decision goes into `moderation_events`, which the API can't change or delete, and can be undone from the list of recent decisions.
- Sample drops show alongside real ones until `NEXT_PUBLIC_SAMPLE_DROPS=off`.

## How uploads work

- People can use a photo or their own 3D model (GLB, or FBX with its texture files) instead of a ready-made object. Their browser does all the processing (`lib/upload/`): three.js reads the file; it becomes static meshes with standard materials, 1 m across and standing on the ground; textures are capped at 1024 px; meshoptimizer (through glTF-Transform) simplifies it to 20,000 triangles or fewer, gently first, then across texture seams for dense scanned or AI-made models (a 1.5-million-triangle, 80 MB GLB takes about 5 seconds); and it renders a thumbnail. Models can have up to 1.5 million triangles and 150 MB of files. Photos are redrawn, which drops their location data, and set in a frame. The result shows on the map before publishing.
- The processed files wait in the browser (IndexedDB) until Publish, then go to the person's own folder in the private `uploads` bucket. Storage enforces the folder, an 8 MB limit and the file types (GLB, PNG, JPEG); the database checks the files are there, and allows 10 uploads a day.
- A drop with an upload always waits for review, whoever posted it. The reviewer's browser downloads the actual file and checks it: no outside references, the real triangle count, size and textures, and its own picture of the model. Approving copies the files to the public `drop-assets` bucket under the upload's id (so the owner's id is never in a public address), with the reviewer's picture as the map thumbnail. Taking a drop down removes those copies.
- Mapbox's model loader needs each vertex attribute in its own buffer and 16-bit indices, so the processed GLB is written that way and no part may have more than 65,535 vertices.

## Layout

```
app/                 screens: start page (/), add, business, report, review, legal; /mine redirects to /
app/auth/confirm/    where sign-in links and Google sign-in land
components/          panel (bottom sheet on phones), map view, place search
components/add/      the add flow and its draft
components/auth/     sign-in and who is signed in
components/mine/     the start page: a welcome with sign-in, then Your drops
components/report/   the report and removal-request form
components/review/   the staff review queue and reports
components/map/      shared map state, and helpers pages use to focus a drop or size the sheet
lib/map/             MapEngine interface, the Mapbox adapter, place search
lib/drops/           drop types, limits, wording, sample drops, nearby drops, your own drops
lib/library/         the ready-made object list
lib/upload/          turning photos and GLB/FBX models into small GLBs in the browser, and uploading them
lib/assets.ts        where uploaded files live, and signed links to private ones
lib/reports.ts       filing a report
lib/review.ts        staff calls for the review queue and reports
lib/supabase/        Supabase clients for the browser and the server
public/library/      generated GLB models and PNG thumbnails
scripts/library/     the generators for public/library/
supabase/migrations/ the schema and its rules
supabase/tests/      permission tests, run against a project
```

Still to come, as each phase needs them: `tests/` (an add-flow browser test).

## Ground rules

- The map is the workspace. Every screen is one floating panel over it: on the left on desktop, a bottom sheet on phones.
- "Add to the map" is the only primary button.
- The database enforces permissions. Nothing relies on checks in the browser.
- A person's location stays on their device. The server only ever gets the map area being viewed.
- Words people see: "Add to the map", "Publish", "In review", "Your drops". Never "coupon", "FBX", "asset" or "tier".
