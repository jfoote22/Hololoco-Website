// Sample content, so the map has something on it before people post.
// The people and businesses are made up. Every drop is placed in metres from
// SAMPLE_CENTRE, the map's starting point, so moving the start moves the whole set.

import { START_VIEW } from "@/lib/map/start";
import type { Placement, PublicDrop } from "./types";

/** Downtown Austin: the centre of the map's starting view. */
export const SAMPLE_CENTRE = START_VIEW.center;

const METRES_PER_DEGREE = 111_320;

/** A placement `east` and `north` metres from the sample centre. */
function at(east: number, north: number, rest: Omit<Placement, "lat" | "lng">): Placement {
  const lat = SAMPLE_CENTRE.lat + north / METRES_PER_DEGREE;
  const lng = SAMPLE_CENTRE.lng + east / (METRES_PER_DEGREE * Math.cos((SAMPLE_CENTRE.lat * Math.PI) / 180));
  return { lat: round(lat), lng: round(lng), ...rest };
}

const round = (n: number) => Math.round(n * 1e6) / 1e6;

const timeZone = "America/Chicago";

/** Samples show alongside real drops until NEXT_PUBLIC_SAMPLE_DROPS is set to "off". */
export const showSamples = process.env.NEXT_PUBLIC_SAMPLE_DROPS !== "off";

const drops: PublicDrop[] = [
  {
    id: "k7p2m9qa",
    type: "offer",
    ownerId: "sample-luigis-slice",
    owner: { name: "Luigi's Slice", kind: "business", verified: true },
    title: "$3 off any large pie",
    description: "Find the slice outside the shop and show the code at the counter.",
    look: { kind: "library", objectId: "pizza" },
    placement: at(25, -5, { height: 4, size: 6, turn: 0 }),
    timeZone,
    timing: { kind: "weekly", blocks: [{ days: [5, 6], start: "17:00", end: "22:00" }] },
    audience: "everyone",
    status: "live",
    offer: {
      savings: "$3 off any large pie",
      quantity: 150,
      remaining: 150,
      perPersonLimit: 1,
      terms: "One per person. Luigi's Slice honours this offer, not Hololoco.",
      rarity: "common",
      kind: "deal",
      category: "food",
      tradeable: true,
      valueCents: null,
      decayPercent: 0,
      decayDays: 7,
      valueNowCents: null,
      inQuests: true,
    },
  },
  {
    id: "c4x8n2rt",
    type: "offer",
    ownerId: "sample-morning-crumb",
    owner: { name: "Morning Crumb Bakery", kind: "business", verified: true },
    title: "Free pastry with any coffee",
    description: "One per person, before 11 am.",
    look: { kind: "library", objectId: "cup" },
    placement: at(-116, 163, { height: 4, size: 6, turn: 0 }),
    timeZone,
    timing: { kind: "weekly", blocks: [{ days: [1, 2, 3, 4, 5], start: "06:00", end: "11:00" }] },
    audience: "everyone",
    status: "live",
    offer: {
      savings: "A free pastry with any coffee",
      quantity: 40,
      remaining: 31,
      perPersonLimit: 1,
      terms: "One per person. Morning Crumb Bakery honours this offer, not Hololoco.",
      rarity: "uncommon",
      kind: "deal",
      category: "coffee",
      tradeable: true,
      valueCents: null,
      decayPercent: 0,
      decayDays: 7,
      valueNowCents: null,
      inQuests: true,
    },
  },
  {
    id: "s9v3h6wd",
    type: "offer",
    ownerId: "sample-stride-running",
    owner: { name: "Stride Running Co.", kind: "business", verified: true },
    title: "$50 off trail shoes",
    description: "Only five out there this weekend. Good luck.",
    look: { kind: "library", objectId: "star" },
    placement: at(170, -62, { height: 7, size: 8, turn: 0 }),
    timeZone,
    timing: { kind: "once", start: "2026-11-21T08:00", end: "2026-11-21T20:00" },
    audience: "everyone",
    status: "live",
    offer: {
      savings: "$50 off trail shoes",
      quantity: 5,
      remaining: 5,
      perPersonLimit: 1,
      terms: "One per person. Stride Running Co. honours this offer, not Hololoco.",
      rarity: "rare",
      kind: "giveaway",
      category: "food",
      tradeable: true,
      valueCents: null,
      decayPercent: 0,
      decayDays: 7,
      valueNowCents: null,
      inQuests: true,
    },
  },
  {
    id: "h2b5q8le",
    type: "object",
    ownerId: "sample-lakeshore-arts",
    owner: { name: "Lakeshore Arts Collective", kind: "business", verified: false },
    title: "Lakeshore gift",
    description: "A floating sculpture above the waterfront walk.",
    look: { kind: "library", objectId: "gift" },
    placement: at(290, -170, { height: 9, size: 10, turn: 20 }),
    timeZone,
    timing: { kind: "always" },
    audience: "everyone",
    status: "live",
  },
  {
    id: "m6j1t4yz",
    type: "message",
    ownerId: "sample-sam-rivera",
    owner: { name: "Sam Rivera", kind: "individual", verified: false },
    title: "Sam and Jo, 25 years",
    description: "We had our first date on this bench.",
    look: { kind: "library", objectId: "heart" },
    placement: at(110, 120, { height: 3, size: 5, turn: 0 }),
    timeZone,
    timing: { kind: "always" },
    audience: "link",
    status: "live",
  },
  {
    id: "w3r7f5uk",
    type: "message",
    ownerId: "sample-priya-n",
    owner: { name: "Priya N.", kind: "individual", verified: false },
    title: "Best sunset in the city",
    description: "Come at golden hour and look west.",
    look: { kind: "library", objectId: "note" },
    placement: at(-180, 110, { height: 4, size: 6, turn: 0 }),
    timeZone,
    timing: { kind: "always" },
    audience: "everyone",
    status: "live",
  },
];

export const sampleDrops: PublicDrop[] = drops.map((drop) => ({ ...drop, sample: true }));
