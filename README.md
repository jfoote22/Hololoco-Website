# Hololoco

An open 3D map of the real world. Anyone can place an object, an offer or a message at a real location, and anyone can find it in a browser, with no app or account.

This repository is the website at hololoco.com. It replaces the 2021 portal and Android app completely and shares no code or data with them.

## Status

Phase 2, adding to the map, is built and waiting on its setup (below) and its gate: sign-in at Publish (an emailed code or link, and Google once it's switched on), the three-step add flow with ready-made objects, schedules, and Your drops with edit, pause and delete. The database enforces the rules. Phase 1's gate, a test on a mid-range phone, is still open too. Offers, uploads, reports and the review queue come in later phases.

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

The map needs a Mapbox public token: copy `.env.example` to `.env.local` and set `NEXT_PUBLIC_MAPBOX_TOKEN`. Without it the panel still lists every drop and says the map couldn't load. Without the Supabase settings the site runs on sample drops only and sign-in is off. Never commit real values.

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

Until the review queue arrives (Phase 3), approve an account's first drop in the SQL editor: `update public.drops set review = 'approved' where id = '<drop id>';`. Staff skip review and limits: `update public.profiles set is_staff = true where id = '<user id>';`.

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
| 3D models | GLB only, drawn by Mapbox's own model layer; three.js only builds the library |
| Place search | Mapbox Geocoding API v6 (addresses and places, not businesses) |

## How the map works

- Each drop is a pin (a real button, so it works with a keyboard) and, from zoom 15.5 in, its 3D model at its place, height and turn. The pin stands on top of the model.
- Models are drawn larger than life so they can be seen from a block away: twice their size plus 12 m (a 6 m object shows as 24 m). The drop keeps its true size for AR later.
- The panel lists every drop in view, which is also how screen reader users reach each pin.
- Drops come from `lib/drops/source.ts`. In Phase 1 that reads the sample set in `lib/drops/sample.ts`; in Phase 2 the same functions query Supabase, and the database decides what the public sees. To move the samples, change `SAMPLE_CENTRE`.
- A person's location is only used in the browser, when they press "Show my location". Place search sends Mapbox the typed words and the centre of the map being viewed.

## How adding works

- The draft is saved in the person's browser as they go, so it survives signing in. Sign-in appears only when they press Publish. The email has a code to type, which keeps them in the same tab, and a link.
- Publishing calls `save_drop` straight from the browser. The database decides everything: who owns what, the limits (10 drops at a time, 5 new a day, 20 public drops within 100 m, 30 m size, 100 m height), and review. Each account's drops stay in review until one has been approved. Its errors are short codes that `lib/drops/mine.ts` turns into plain words.
- Visitors can't read any table. Public drops come only from the `public_*` functions, which return approved, unpaused drops (and only those within their hours, for the map).
- Drop pages are cached for a few minutes. Saving, pausing or deleting a drop refreshes its page.
- Sample drops show alongside real ones until `NEXT_PUBLIC_SAMPLE_DROPS=off`.

## Layout

```
app/                 screens: map (/), d/[id] (+ link preview image), add, mine, business, report, review, legal
app/auth/confirm/    where sign-in links and Google sign-in land
components/          panel (bottom sheet on phones), map view, search, filter, list, share
components/add/      the add flow and its draft
components/auth/     sign-in and who is signed in
components/mine/     Your drops
components/map/      shared map state, and helpers pages use to focus a drop or size the sheet
lib/map/             MapEngine interface, the Mapbox adapter, place search
lib/drops/           drop types, limits, wording, sample drops, public reads, your own drops
lib/library/         the ready-made object list
lib/supabase/        Supabase clients for the browser, the server and public reads
public/library/      generated GLB models and PNG thumbnails
scripts/library/     the generators for public/library/
supabase/migrations/ the schema and its rules
supabase/tests/      permission tests, run against a project
```

Still to come, as each phase needs them: `supabase/functions/` (upload checks) and `tests/` (an add-flow browser test).

## Ground rules

- The map is the product. Every screen is one floating panel over it: on the left on desktop, a bottom sheet on phones.
- "Add to the map" is the only primary button.
- The database enforces permissions. Nothing relies on checks in the browser.
- A person's location stays on their device. The server only ever gets the map area being viewed.
- Words people see: "Add to the map", "Publish", "In review", "Your drops". Never "coupon", "FBX", "asset" or "tier".
