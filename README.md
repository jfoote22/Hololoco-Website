# Hololoco

An open 3D map of the real world. Anyone can place an object, an offer or a message at a real location, and anyone can find it in a browser, with no app or account.

This repository is the website at hololoco.com. It replaces the 2021 portal and Android app completely and shares no code or data with them.

## Status

Phase 0: the empty app. Every screen exists as a placeholder over a stand-in map, so the layout and routes are in place before features land.

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

Nothing needs environment variables yet. When Mapbox (Phase 1) and Supabase (Phase 2) arrive, copy `.env.example` to `.env.local` and fill it in. Never commit real values.

## Stack

| Layer | Choice |
| --- | --- |
| App | Next.js 16 (App Router, Cache Components), TypeScript, Tailwind CSS 4 |
| Hosting | Vercel |
| Data and sign-in | Supabase: Postgres with PostGIS, Auth, Storage |
| Map | Mapbox GL JS with three.js models, behind `lib/map/engine.ts` |
| 3D format | GLB only |

## Layout

```
app/                 screens: map (/), d/[id], add, mine, business, report, review, legal
components/          panel, map view, shared pieces
lib/map/             MapEngine interface (the Mapbox adapter comes in Phase 1)
lib/drops/           drop types and placement limits
```

Still to come, as each phase needs them: `lib/supabase/` (clients), `public/library/` (ready-made GLB objects), `supabase/migrations/` (schema and row-level rules), `supabase/functions/` (upload checks), and `tests/` (permission tests and an add-flow browser test).

## Ground rules

- The map is the product. Every screen is one floating panel over it: on the left on desktop, a bottom sheet on phones.
- "Add to the map" is the only primary button.
- The database enforces permissions. Nothing relies on checks in the browser.
- A person's location stays on their device. The server only ever gets the map area being viewed.
- Words people see: "Add to the map", "Publish", "In review", "Your drops". Never "coupon", "FBX", "asset" or "tier".
