# Hololoco

Hololoco puts offers, 3D objects and messages at real places. This website is where businesses sign in to place and manage them. People find them in the Hololoco phone app, a separate Unity app still to come, which reads the same Supabase database and accounts.

This repository is the website at hololoco.com. It replaces the 2021 portal and Android app completely and shares no code or data with them.

## Status

The website became the business side on 2026-11-14: the start page asks people to sign in, and the public browsing (type filters, the nearby list, drop pages, View in AR) moved to the app. The same day, offers arrived, with a rarity the business sets (common, uncommon or rare) and a choice to be part of quests. Drops now go live at once; a complaint puts an account's drops in front of a person, and three strikes suspend it. An automatic check by Claude is built but switched off. The quest builder followed: the database links opted-in offers from nearby businesses into quests by itself, themed when they're all one kind of business. On 2026-11-15 came plans (Free, Plus, Business and Events, with limits the database enforces), the app's back end (capturing, the inventory, redeeming at the counter, trading, XP, quest progress and events; see [docs/app-api.md](docs/app-api.md)), and the business pages for redeeming codes and making events. Next comes the Unity app itself.

Phase 3, safety, has started: the review queue, reports, and photo and 3D model uploads are built. Rules on where drops can go and the legal pages have moved later in the plan. Phase 2, adding to the map, is built and waiting on its gate: sign-in (Google, or an emailed code or link), the three-step add flow with ready-made objects, schedules, and Your drops with edit, pause and delete. The database enforces the rules. Phase 1's gate, a test on a mid-range phone, is still open too. Offers, uploads, reports and the review queue come in later phases.

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
7. The automatic photo check: deploy `supabase/functions/scan-photo` with JWT verification off, enable the Cloud Vision API in Google Cloud (it needs billing; about $1.50 per 1,000 photos), create an API key limited to Cloud Vision, and add it as the Edge Function secret `GOOGLE_VISION_API_KEY`. Without it, every photo goes to a person. It uses the `project_url` vault secret from the next step.
8. The automatic check (off unless you turn it on): in the SQL editor, `select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');` (where the database sends its calls). Deploy `supabase/functions/check-drop` with JWT verification off (`supabase functions deploy check-drop --no-verify-jwt`; it checks for itself). Under Edge Functions → Secrets, add `ANTHROPIC_API_KEY` and, optionally, `MAPBOX_TOKEN` (the public `pk.` token, so the check can see what's around each spot). Then `select private.set_automatic_check(true);` turns it on. Without the API key, everything it would look at goes to a person.

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
| Automatic check | Claude Opus 5.5 through the Anthropic SDK, in a Supabase Edge Function (Deno) |

## How the map works

- The map is the signed-in person's workspace. Their own drops show in every state (in review, live, paused, not approved), each as a pin (a real button, so it works with a keyboard) and, from zoom 15.5 in, its 3D model at its place, height and turn. The pin stands on top of the model. Clicking one opens it for editing.
- Other people's public drops nearby show as small, dimmed pins without their models, so people can see what's around when placing theirs. They can't be clicked. Signed out, the map shows no drops.
- Models are drawn larger than life so they can be seen from a block away: twice their size plus 12 m (a 6 m object shows as 24 m). The drop keeps its true size for AR in the app.
- The person's own drops come from `my_drops`, with signed links for uploads that aren't public yet. Other people's come from `public_drops_in_bounds` through `lib/drops/source.ts`, plus the sample set in `lib/drops/sample.ts`. To move the samples, change `SAMPLE_CENTRE`.
- A person's location is only used in the browser, when they press "Show my location". Place search sends Mapbox the typed words and the centre of the map being viewed.

## How adding works

- The start page asks people to sign in with Google or an emailed code. The email has a code to type, which keeps them in the same tab, and a link. The add flow's draft is saved in the browser as they go, so someone who starts it signed out can still sign in at Publish without losing it.
- Publishing calls `save_drop` straight from the browser. The database decides everything: who owns what, the limits (the plan's drops at a time and new a day, 20 public drops within 100 m, 30 m size, 100 m height), and review. Its errors are short codes that `lib/drops/mine.ts` turns into plain words.
- Drops go live as soon as they're saved, with three exceptions that wait for a person: photos the automatic photo check flags, every 3D model, and everything from an account under review. An account is under review while one of its drops has an open report (a complaint), and from its first strike on. Each drop a person takes down or doesn't approve is a strike; keeping a reported drop is not, and with no strikes the account goes back to normal. Three strikes suspend the account: its drops leave the map, and it can't add or change any, only delete them. Undoing a decision in `/review` takes its strike back. Lift a suspension in the SQL editor with `update public.profiles set strikes = 0 where id = '<user id>';`.
- Offers say what kind they are (a coupon or deal, a giveaway, or a gift card), what people get, how many there are in all, how many each person can claim, the terms, and what kind of business they're from. The business sets how rare the offer is: common, uncommon or rare. That decides how it looks in the app, how often people come across it, and which stage of a quest it can be in. Offers join quests only if the business ticks the box, and can be traded in the app unless the business unticks that. `claimed` counts captures and `redeemed` redemptions; owners can't write either, and Your drops shows both.
- Visitors can't read any table. Public drops come only from the `public_*` functions, which return approved, unpaused drops (and only those within their hours, for the map).
- Property owners can ask for a removal at `/report`, with no account. The app will file reports through the same `file_report` function. A serious report (danger, or someone's personal information) hides the drop at once, and so do reports from three different people within a week; it goes back to review. Ten reports a day per person. People without an account are told apart by a keyed hash of their connection that changes weekly; their address isn't stored. Only staff can read reports.
- Staff work through reports and the queue at `/review`: approve, or don't approve with a reason the owner sees in Your drops. Editing a drop that wasn't approved sends it back to the queue. Every decision goes into `moderation_events`, which the API can't change or delete, and can be undone from the list of recent decisions.
- Sample drops show alongside real ones until `NEXT_PUBLIC_SAMPLE_DROPS=off`.

## How quests work

- A quest chains offers from different businesses into stages: a common offer first, one or two uncommon ones, and a rare one last (3 or 4 stages). The database builds them by itself every 15 minutes (pg_cron job `build-quests`, `private.refresh_quests`), from offers whose businesses ticked "Let it be part of quests".
- Every stage is live, in stock and from a different business, and the stages are open together at least 4 hours a week, in one time zone. One-time offers don't join. Each leg is at most a 20-minute walk (1.6 km); where businesses are spread out, as in rural areas, legs can stretch to 5 km and then 15 km. An offer is in one quest at a time.
- The builder starts from each rare offer, the scarcest, and works back: the nearest uncommon offer, perhaps a second one before it, and the nearest common offer to start from. A quest is named after its first and last business.
- A quest stays as built until a stage drops out (paused, sold out, taken down, out of quests, a different rarity, moved too far, or its hours no longer overlap). Then it's retired with the reason, and its other offers can join a new one. A stage taken down disappears from the public quest at once, before the next rebuild.
- The app reads quests through `public_quests_in_bounds` and `public_quest` (any visitor). Each quest has its stages in order with their drops, `openHours` (168 characters, one per hour of the week from Sunday midnight, `1` when every stage is open) and `openNow`. Retired quests stay readable for players part-way through.
- Businesses see "Stage 2 of 4 in a quest" in Your drops, with the other stages and the route on the map. Staff see every quest, and those retired this week with why, at `/quests`, and can build quests at once.
- When every stage is one kind of business with a theme (coffee, food, bakeries, bars, shopping, beauty, fitness, fun), the quest gets that theme: "Coffee crawl: Bean Co. to The Roastery". The builder tries themed quests first at each distance, then mixed ones. A themed quest retires if one of its offers changes category.
- Players capture stages in order in the app; later stages only show up once the stage before is done, and finishing earns a bonus.

## Plans

- Every account has a plan, and the database enforces it (`drops_before_write`, `plan_of`). Free: messages and objects, with a ready-made look or a photo, 10 drops at a time and 5 new a day. Plus: 50 and 20, and uploaded 3D models. Business: 200 and 50, and offers. Events: 500 and 100, and events. Change the numbers in the `plans` table; the website reads them from there.
- There's no payment yet. People ask for a plan at `/plan`, saying what it's for; staff grant or decline it at the bottom of `/review`. Or, in the SQL editor: `select public.set_plan('<user id>', 'business');`. A plan with an end date (`plan_until`, for payments later) counts as Free once it has passed; existing offers stay editable.
- Accounts that had offers before plans arrived were put on Business.

## How playing works (the app)

The Hololoco app calls Postgres functions only; [docs/app-api.md](docs/app-api.md) lists every one, its answer and its errors.

- `app_nearby` returns drops, items left on the map, quests and events around the player. Rarer offers show up on fewer days (uncommon about 60%, rare about 30%, per player per day), a quest's later stages only once the stage before is done, and event stops always.
- `capture` checks the phone's position (within about 40 m, at most 100 captures a day, no faster than 250 km/h between captures), gives an item when there's one to give, and moves the player on in quests and events. XP: a message 5, an object 10, an offer 20 to 150 by rarity, plus quest and event bonuses. Level 2 is at 100 XP, 3 at 300, 4 at 600.
- Redeeming: the player taps Redeem and shows a 6-digit code that lasts 10 minutes; the business types it in at `/redeem`. Only the business that made the offer can confirm it, and each code works once.
- Trading: players find each other by handle and see only the items others put up for trade. A trade fails, moving nothing, if an item changed hands since. Items can be left on the map for anyone (they come back after 7 days) or discarded (an offer goes back in stock). The per-person limit counts captures, so whoever holds a traded offer can redeem it.
- Events (the Events plan): a business makes a hunt or a trail from 2 to 20 of its own drops at `/events`, for up to 92 days, with XP for each stop, a bonus and points for finishing, and optionally one of its offers as the reward.
- Every 10 minutes, `private.play_upkeep` returns items nobody picked up, expires week-old trades and clears old codes.
- Offers can have a value that drops over time (`value_cents`, `decay_percent` every `decay_days`), like old Coupemon's coupons. `offer_value_now` works it out from the database's clock, so a phone's clock can't change it; the app shows it, and the business sees it at the counter.

## How the automatic photo check works

- Photos are free to post and need no person unless something looks wrong. Every new photo upload is queued (a trigger on `assets`) and the database asks the `scan-photo` Edge Function to check it (pg_net, after the upload commits). The drop shows "Checking" to its owner meanwhile.
- The function checks every picture the photo will show, with Google Cloud Vision SafeSearch: the photo, its pin thumbnail, and each picture inside its framed 3D version, so a different picture can't hide in the model. It also checks the framed model is the kind the website makes: at most 200 triangles, at most 2 pictures, no links to outside files. The rules are in `supabase/functions/scan-photo/scan.ts`: adult content from "possible" up, violence, racy or graphic medical content from "likely" up.
- A clean photo's files are copied to the public bucket and `private.finish_photo_scan` publishes it; the drops waiting only for it go live (logged as "Automatic photo check"), unless the account is under review, the drop is reported, or a person turned it down before. A flagged photo waits in `/review` with what was found. If the check can't run (no `GOOGLE_VISION_API_KEY`, or an error), a person checks the photo, as before.
- Still to add: matching against known illegal images (Microsoft PhotoDNA, which needs an application).

## How the automatic check works (switched off)

- It's built but off: people do every review for now. `select private.set_automatic_check(true);` turns it on (it needs `ANTHROPIC_API_KEY`), and `false` turns it off again, along with its retry job.
- While it's on, it looks first at whatever would otherwise wait for a person: drops and changes from accounts under review, and photos and models (which it can't approve, only comment on). Staff drops skip it.
- A trigger on `drops` asks the `check-drop` Edge Function (pg_net, after the save commits). The function claims the drop, looks up what's around the spot on Mapbox, and asks Claude (Opus 5.5, structured output) whether it can go live. It writes the answer back through `private.claim_check`, `private.finish_check` and `private.fail_check`, over the Edge Function's direct database connection; the API can't reach those functions, and only one call can claim a drop, so the function's public address is safe.
- The check approves a drop or holds it for a person, saying why. It never turns anything down itself. It can't approve a drop whose photo or model a person hasn't approved, one with an open report, or one a person turned down before. Alcohol, tobacco, cannabis, gambling, weapons and adult content always go to a person, and so do sweepstakes and cash giveaways.
- For offers it suggests a rarity, which the owner can take with one click in Your drops, and for any drop it can give a placement tip. Staff see its reasons and concerns in the review queue; owners see only its note to them.
- While it's on, a job runs every minute (pg_cron, `private.retry_checks`): it sends again what nobody answered, retries failures, and after three attempts hands the drop to a person. Each account gets 40 checks a day; past that a person checks the rest. Every attempt, with what it said and the tokens it used, is in `drop_checks`. Automatic approvals go in the moderation log as "Automatic check".
- The prompt and the answer's shape are in `supabase/functions/check-drop/check.ts`.

## How uploads work

- People can use a photo or their own 3D model (GLB, or FBX with its texture files) instead of a ready-made object. Their browser does all the processing (`lib/upload/`): three.js reads the file; it becomes static meshes with standard materials, 1 m across and standing on the ground; textures are capped at 1024 px; meshoptimizer (through glTF-Transform) simplifies it to 20,000 triangles or fewer, gently first, then across texture seams for dense scanned or AI-made models (a 1.5-million-triangle, 80 MB GLB takes about 5 seconds); and it renders a thumbnail. Models can have up to 1.5 million triangles and 150 MB of files. Photos are redrawn, which drops their location data, and set in a frame. The result shows on the map before publishing.
- The processed files wait in the browser (IndexedDB) until Publish, then go to the person's own folder in the private `uploads` bucket. Storage enforces the folder, an 8 MB limit and the file types (GLB, PNG, JPEG); the database checks the files are there, and allows 10 uploads a day.
- A drop with an upload always waits for review, whoever posted it. The reviewer's browser downloads the actual file and checks it: no outside references, the real triangle count, size and textures, and its own picture of the model. Approving copies the files to the public `drop-assets` bucket under the upload's id (so the owner's id is never in a public address), with the reviewer's picture as the map thumbnail. Taking a drop down removes those copies.
- Mapbox's model loader needs each vertex attribute in its own buffer and 16-bit indices, so the processed GLB is written that way and no part may have more than 65,535 vertices.

## Layout

```
app/                 screens: start page (/), add, plan, redeem, events, business, report, review, quests, legal; /mine redirects to /
app/auth/confirm/    where sign-in links and Google sign-in land
components/          panel (bottom sheet on phones), map view, place search
components/add/      the add flow and its draft
components/auth/     sign-in and who is signed in
components/mine/     the start page: a welcome with sign-in, then Your drops
components/report/   the report and removal-request form
components/review/   the staff review queue and reports
components/quests/   the staff list of quests
components/plan/     Your plan, and asking for a bigger one
components/redeem/   typing in a player's code at the counter
components/events/   making and running events
components/map/      shared map state, and helpers pages use to focus a drop or size the sheet
lib/map/             MapEngine interface, the Mapbox adapter, place search
lib/drops/           drop types, limits, wording, sample drops, nearby drops, your own drops
lib/library/         the ready-made object list
lib/upload/          turning photos and GLB/FBX models into small GLBs in the browser, and uploading them
lib/assets.ts        where uploaded files live, and signed links to private ones
lib/quests.ts        reading quests, and their routes and hours in words
lib/plans.ts         plans, plan requests, and what a plan allows
lib/redeem.ts        confirming codes, and recent redemptions
lib/events.ts        a business's events
lib/reports.ts       filing a report
lib/review.ts        staff calls for the review queue and reports
lib/supabase/        Supabase clients for the browser and the server
public/library/      generated GLB models and PNG thumbnails
scripts/library/     the generators for public/library/
supabase/migrations/ the schema and its rules
supabase/functions/  check-drop and scan-photo, the automatic checks (Deno, deployed to Supabase, not Vercel)
docs/app-api.md      the app's back end: every function the Unity app calls
supabase/tests/      permission tests, run against a project
```

Still to come, as each phase needs them: `tests/` (an add-flow browser test).

## Ground rules

- The map is the workspace. Every screen is one floating panel over it: on the left on desktop, a bottom sheet on phones.
- "Add to the map" is the only primary button.
- The database enforces permissions. Nothing relies on checks in the browser.
- A person's location stays on their device. The server only ever gets the map area being viewed.
- Words people see: "Add to the map", "Publish", "In review", "Your drops". Never "coupon", "FBX", "asset" or "tier".
