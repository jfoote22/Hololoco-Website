// Found events, for staff: games, shows, festivals, business events, giveaways and
// deals that the finder (supabase/functions/find-events) found around town, waiting
// to be approved onto the map. Every call is checked by the database: anyone who
// isn't staff gets "not_allowed" back, whatever this page shows.

import type { LngLat } from "@/lib/map/engine";
import { browserClient } from "@/lib/supabase/browser";

export type FoundCategory =
  | "sports" | "music" | "comedy" | "theater" | "arts" | "festival" | "food"
  | "business" | "community" | "family" | "giveaway" | "deal" | "other";

export type FoundStatus = "pending" | "approved" | "rejected" | "expired";

/** How its spot was found: its street address, a venue already placed, the finder's estimate, or a person. */
export type PlacedBy = "address" | "venue" | "estimate" | "staff";

export type FoundEvent = {
  id: string;
  status: FoundStatus;
  category: FoundCategory;
  title: string;
  summary: string;
  /** Local times in the event's zone: "YYYY-MM-DDTHH:MM". */
  start: string;
  end: string;
  allDay: boolean;
  timeNote: string;
  timeZone: string;
  venue: string;
  address: string;
  placement: LngLat;
  placedBy: PlacedBy;
  price: string;
  free: boolean;
  url: string | null;
  ticketUrl: string | null;
  sources: string[];
  organizer: string;
  confidence: "high" | "medium" | "low";
  note: string;
  /** The finder's topic, or null for events added by hand. */
  topic: string | null;
  /** The drop it became, once approved. */
  dropId: string | null;
  reviewedAt: string | null;
  rejectReason: string | null;
  foundAt: string;
};

export type FinderSearch = {
  topic: string;
  status: "queued" | "submitted" | "continue" | "placing" | "done" | "failed";
  added: number;
  duplicates: number;
  skipped: number;
  costCents: number;
  error: string | null;
};

export type FinderState = {
  running: boolean;
  lastRun: { id: number; status: string; createdAt: string; finishedAt: string | null; searches: FinderSearch[] } | null;
  costCents30Days: number;
};

export type FoundQueue = {
  items: FoundEvent[];
  counts: Record<FoundStatus, number>;
  finder: FinderState;
};

export type FoundDecision = "approve" | "reject" | "pending" | "move";

export type FoundChanges = { at?: LngLat; title?: string; reason?: string };

export type BulkResult = { done: number; failed: { id: string; error: string }[] };

/** What the review screen needs from the database; a stand-in can be passed for previews. */
export type FoundApi = {
  load(status: FoundStatus): Promise<FoundQueue>;
  review(id: string, decision: FoundDecision, changes?: FoundChanges): Promise<FoundEvent>;
  reviewMany(ids: string[], decision: "approve" | "reject" | "pending", reason?: string): Promise<BulkResult>;
  runFinder(): Promise<void>;
};

type DbError = { message?: string; code?: string } | null;

export function foundErrorText(error: DbError | Error): string {
  const message = error?.message ?? "";
  if (message.includes("not_allowed")) return "Only Hololoco staff can do that.";
  if (message.includes("already_over")) return "That event has already ended, so it can't go on the map.";
  if (message.includes("already_running")) return "The finder is already searching. New events show up here as it finishes.";
  if (message.includes("not_found")) return "That event isn't there anymore. Reload the list.";
  if (message.includes("bad_location")) return "That spot isn't a real place on the map.";
  if (message.includes("Failed to fetch") || message.includes("NetworkError"))
    return "Couldn't reach Hololoco. Check your connection and try again.";
  return "Something went wrong. Try again.";
}

async function call<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const client = browserClient();
  if (!client) throw new Error("Couldn't reach Hololoco.");
  const { data, error } = await client.rpc(fn, args);
  if (error) throw new Error(foundErrorText(error));
  return data as T;
}

export const foundApi: FoundApi = {
  load: (status) => call<FoundQueue>("found_queue", { p_status: status }),
  review: (id, decision, changes = {}) =>
    call<FoundEvent>("review_found", {
      found_id: id,
      decision,
      lat: changes.at?.lat ?? null,
      lng: changes.at?.lng ?? null,
      title: changes.title ?? null,
      reason: changes.reason ?? null,
    }),
  reviewMany: (ids, decision, reason) =>
    call<BulkResult>("review_found_many", { found_ids: ids, decision, reason: reason ?? null }),
  runFinder: async () => {
    await call("run_finder", { area: "austin" });
  },
};

/** How many found events are waiting, for staff; null for anyone else. */
export async function waitingCount(): Promise<number | null> {
  try {
    return await call<number>("found_waiting_count", {});
  } catch {
    return null;
  }
}

export const categoryLabel: Record<FoundCategory, string> = {
  sports: "Sports",
  music: "Music",
  comedy: "Comedy",
  theater: "Theater",
  arts: "Art",
  festival: "Festival",
  food: "Food and drink",
  business: "Business",
  community: "Community",
  family: "Family",
  giveaway: "Giveaway",
  deal: "Deal",
  other: "Other",
};

/** The ready-made object an approved event shows as. Keep in step with private.found_object() in the database. */
export const categoryObject: Record<FoundCategory, string> = {
  sports: "star",
  music: "star",
  comedy: "note",
  theater: "star",
  arts: "star",
  festival: "star",
  food: "pizza",
  business: "cup",
  community: "heart",
  family: "heart",
  giveaway: "gift",
  deal: "gift",
  other: "star",
};

export const topicLabel: Record<string, string> = {
  "ut-sports": "UT and college sports",
  "pro-sports": "Pro sports and races",
  concerts: "Concerts",
  comedy: "Comedy",
  "stage-arts": "Theater and art",
  festivals: "Festivals and markets",
  "food-drink": "Food and drink",
  business: "Business events",
  "giveaways-deals": "Giveaways and deals",
  "family-outdoors": "Family and outdoors",
};

export const rejectReasons = ["Duplicate", "Wrong or missing details", "Not in the area", "Not a fit for the map"] as const;

/** "2026-11-21T19:30" read as written, with no time zone shifting. */
function parseLocal(value: string): Date {
  const [date, time = "00:00"] = value.split("T");
  const [y, m, d] = date.split("-").map(Number);
  const [h, min] = time.split(":").map(Number);
  return new Date(Date.UTC(y, m - 1, d, h, min));
}

const dayText = (d: Date) =>
  d.toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric", timeZone: "UTC" });

const clockText = (d: Date) =>
  d.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit", timeZone: "UTC" }).replace(":00", "").toLowerCase();

/** "Sat, Nov 21 · 7 pm – 10 pm", "Fri, Nov 20 – Sun, Dec 20", "Sat, Nov 21 · all day". */
export function whenText(event: Pick<FoundEvent, "start" | "end" | "allDay">): string {
  const start = parseLocal(event.start);
  // An all-day event ends at midnight after its last day.
  const end = new Date(parseLocal(event.end).getTime() - (event.allDay ? 60_000 : 0));
  const hours = (end.getTime() - start.getTime()) / 3_600_000;
  const sameDay = dayText(start) === dayText(end);
  if (event.allDay) return sameDay ? `${dayText(start)} · all day` : `${dayText(start)} – ${dayText(end)}`;
  // A late show that ends after midnight still reads as one evening.
  if (sameDay || hours <= 10) return `${dayText(start)} · ${clockText(start)} – ${clockText(end)}`;
  return `${dayText(start)}, ${clockText(start)} – ${dayText(end)}`;
}

export type When = "any" | "today" | "weekend" | "week" | "month";

export const whenOptions: { id: When; label: string }[] = [
  { id: "any", label: "Any time" },
  { id: "today", label: "Today" },
  { id: "weekend", label: "This weekend" },
  { id: "week", label: "Next 7 days" },
  { id: "month", label: "Next 30 days" },
];

/** "YYYY-MM-DD" in a time zone, for today plus some days. */
function localDay(timeZone: string, plusDays = 0): string {
  const date = new Date(Date.now() + plusDays * 86_400_000);
  return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(date);
}

/** Whether an event is on during the chosen stretch, in its own time zone. */
export function isWhen(event: Pick<FoundEvent, "start" | "end" | "allDay" | "timeZone">, when: When): boolean {
  if (when === "any") return true;
  const first = event.start.slice(0, 10);
  // An all-day event ends at midnight after its last day.
  const last = new Date(parseLocal(event.end).getTime() - (event.allDay ? 60_000 : 0)).toISOString().slice(0, 10);
  const today = localDay(event.timeZone);
  const overlaps = (from: string, to: string) => first <= to && last >= from;
  if (when === "today") return overlaps(today, today);
  if (when === "week") return overlaps(today, localDay(event.timeZone, 6));
  if (when === "month") return overlaps(today, localDay(event.timeZone, 29));
  // This weekend: Friday to Sunday, or what's left of it.
  const weekday = new Date(`${today}T12:00:00Z`).getUTCDay();
  const toFriday = weekday === 0 ? -2 : weekday === 6 ? -1 : 5 - weekday;
  const friday = localDay(event.timeZone, Math.max(0, toFriday));
  const sunday = localDay(event.timeZone, toFriday + 2);
  return overlaps(friday, sunday);
}

/** Straight-line metres between two spots. */
export function metresBetween(a: LngLat, b: LngLat): number {
  const r = (d: number) => (d * Math.PI) / 180;
  const x = r(b.lng - a.lng) * Math.cos(r((a.lat + b.lat) / 2));
  const y = r(b.lat - a.lat);
  return Math.sqrt(x * x + y * y) * 6_371_008.8;
}

export function distanceText(metres: number): string {
  return metres < 1000 ? `${Math.round(metres / 10) * 10} m` : `${(metres / 1000).toFixed(metres < 10_000 ? 1 : 0)} km`;
}

/** Events within about 10 m of each other share a pin. */
export function spotKey(event: Pick<FoundEvent, "placement">): string {
  return `${event.placement.lat.toFixed(4)},${event.placement.lng.toFixed(4)}`;
}

export const placedByText: Record<PlacedBy, string> = {
  address: "Placed at its street address.",
  venue: "Placed at a venue already on the map.",
  estimate: "The spot is the finder's estimate. Check it, and drag the pin if it's off.",
  staff: "Placed by a person.",
};
