# Hololoco

An open 3D map of the real world. Anyone can place an object, an offer or a message at a real location, and anyone can find it in a browser, with no app or account.

This repository is the website at hololoco.com. It replaces the 2021 portal and Android app completely and shares no code or data with them.

## Status

Phase 1, the map, is built and waiting on its gate: the 3D map, place and drop search, the type filter, pins with 3D models, the drop page with a link preview, and six sample drops in Lower Manhattan. The gate is a test on a mid-range phone. The other screens are still placeholders.

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

The map needs a Mapbox public token: copy `.env.example` to `.env.local` and set `NEXT_PUBLIC_MAPBOX_TOKEN`. Without it the panel still lists every drop and says the map couldn't load. Supabase settings come in Phase 2. Never commit real values.

If a change to `app/globals.css` doesn't show up while `npm run dev` is running, restart it.

### Ready-made objects

The library in `public/library/` is generated, not drawn by hand:

```sh
node scripts/library/build-models.mjs       # GLB files, 1 m across, from simple shapes
node scripts/library/render-thumbnails.mjs  # PNG thumbnails, rendered with headless Chrome
```

Then list any new object in `lib/library/objects.ts`.

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

## Layout

```
app/                 screens: map (/), d/[id] (+ link preview image), add, mine, business, report, review, legal
components/          panel (bottom sheet on phones), map view, search, filter, list, share
components/map/      shared map state, and helpers pages use to focus a drop or size the sheet
lib/map/             MapEngine interface, the Mapbox adapter, place search
lib/drops/           drop types, limits, wording, sample drops, where drops come from
lib/library/         the ready-made object list
public/library/      generated GLB models and PNG thumbnails
scripts/library/     the generators for public/library/
```

Still to come, as each phase needs them: `lib/supabase/` (clients), `supabase/migrations/` (schema and row-level rules), `supabase/functions/` (upload checks), and `tests/` (permission tests and an add-flow browser test).

## Ground rules

- The map is the product. Every screen is one floating panel over it: on the left on desktop, a bottom sheet on phones.
- "Add to the map" is the only primary button.
- The database enforces permissions. Nothing relies on checks in the browser.
- A person's location stays on their device. The server only ever gets the map area being viewed.
- Words people see: "Add to the map", "Publish", "In review", "Your drops". Never "coupon", "FBX", "asset" or "tier".
