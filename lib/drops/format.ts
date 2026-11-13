// Plain-language words for drops, shared by the map, lists, drop pages and link previews.

import { libraryObject } from "@/lib/library/objects";
import type { DropType, Offer, PublicDrop, Timing, Weekday, WeeklyBlock } from "./types";

export const typeLabel: Record<DropType, string> = {
  object: "Object",
  message: "Message",
  offer: "Offer",
};

/** "Offer from Luigi's Slice" */
export function byline(drop: PublicDrop): string {
  return `${typeLabel[drop.type]} from ${drop.owner.name}`;
}

/** "Offer from Luigi's Slice, verified business" */
export function bylineLong(drop: PublicDrop): string {
  const verified = drop.owner.kind === "business" && drop.owner.verified;
  return verified ? `${byline(drop)}, verified business` : byline(drop);
}

export function thumbnailFor(drop: PublicDrop): string | null {
  return drop.look.kind === "library" ? (libraryObject(drop.look.objectId)?.thumbnail ?? null) : null;
}

export function modelFor(drop: PublicDrop): string | null {
  return drop.look.kind === "library" ? (libraryObject(drop.look.objectId)?.model ?? null) : null;
}

/** "Saves $3, one per person" */
export function savingsText(offer: Offer): string {
  const each = offer.perPersonLimit === 1 ? "one per person" : `up to ${offer.perPersonLimit} per person`;
  const saves = offer.savings.startsWith("$") ? `Saves ${offer.savings}` : `Get ${offer.savings}`;
  return `${saves}, ${each}`;
}

/** "150 left at this location" */
export function remainingText(offer: Offer): string {
  if (offer.remaining <= 0) return "All claimed";
  return `${offer.remaining} left at this location`;
}

const DAY_NAMES = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const MONTHS = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
];

/** "17:00" → "5 pm", "06:30" → "6:30 am", "12:00" → "noon", "00:00" → "midnight" */
export function clockText(hhmm: string): string {
  const [h, m] = hhmm.split(":").map(Number);
  if (m === 0 && h === 12) return "noon";
  if (m === 0 && (h === 0 || h === 24)) return "midnight";
  const hour = h % 12 === 0 ? 12 : h % 12;
  const suffix = h < 12 || h === 24 ? "am" : "pm";
  return m === 0 ? `${hour} ${suffix}` : `${hour}:${String(m).padStart(2, "0")} ${suffix}`;
}

/** [5, 6] → "Fridays and Saturdays", [1..5] → "Weekdays" */
export function daysText(days: Weekday[]): string {
  const set = [...new Set(days)].sort((a, b) => ((a + 6) % 7) - ((b + 6) % 7));
  const key = set.join(",");
  if (set.length === 7) return "Every day";
  if (key === "1,2,3,4,5") return "Weekdays";
  if (key === "6,0") return "Weekends";
  const names = set.map((d) => `${DAY_NAMES[d]}s`);
  return names.length === 1 ? names[0] : `${names.slice(0, -1).join(", ")} and ${names.at(-1)}`;
}

function blockText(block: WeeklyBlock): string {
  return `${daysText(block.days)}, ${clockText(block.start)} to ${clockText(block.end)}`;
}

/** "2026-11-21T08:00" → { date: "Saturday, November 21", time: "8 am" }, read in the drop's own zone. */
function localDateTime(value: string) {
  const [date, time = "00:00"] = value.split("T");
  const [y, mo, d] = date.split("-").map(Number);
  const weekday = DAY_NAMES[new Date(Date.UTC(y, mo - 1, d)).getUTCDay()];
  return { day: date, date: `${weekday}, ${MONTHS[mo - 1]} ${d}`, time: clockText(time.slice(0, 5)) };
}

/** When a drop is on the map, or null when it always is. Times are the drop's local time. */
export function timingText(timing: Timing): string | null {
  switch (timing.kind) {
    case "always":
      return null;
    case "weekly":
      return timing.blocks.map(blockText).join("; ");
    case "once": {
      const start = localDateTime(timing.start);
      const end = localDateTime(timing.end);
      return start.day === end.day
        ? `${start.date}, ${start.time} to ${end.time}`
        : `${start.date}, ${start.time} to ${end.date}, ${end.time}`;
    }
  }
}
