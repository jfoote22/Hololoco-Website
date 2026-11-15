// Quests: offers from different businesses chained into stages, common first and
// rare last. The database builds them (the quests migration); the website only
// shows them: owners see their offer's quest, staff see them all.

import { daysText, clockText } from "@/lib/drops/format";
import { dropFromJson, type DropJson } from "@/lib/drops/json";
import { errorText } from "@/lib/drops/mine";
import type { PublicDrop, QuestPlace, Rarity, Weekday } from "@/lib/drops/types";
import type { LngLat, MapBounds } from "@/lib/map/engine";
import { browserClient } from "@/lib/supabase/browser";

export type QuestStage = {
  position: number;
  rarity: Rarity;
  /** Null when the offer isn't public any more (taken down since the last rebuild). */
  drop: PublicDrop | null;
};

export type Quest = {
  id: string;
  name: string;
  /** The category every stage shares, when the quest has a theme ("coffee"), and the theme's name ("Coffee crawl"). */
  theme?: string | null;
  themeName?: string | null;
  status: "active" | "retired";
  stageCount: number;
  /** The longest leg allowed when it was built: 1600 (a 20-minute walk), 5000 or 15000 m. */
  maxLegMetres: number;
  timeZone: string;
  /** 168 characters, "1" for each hour of the week (Sunday 00:00 first) when every stage is open. */
  openHours: string;
  openNow: boolean;
  builtAt: string;
  stages: QuestStage[];
  /** Staff only. */
  retiredAt?: string | null;
  retiredReason?: string | null;
};

type QuestJson = Omit<Quest, "stages"> & {
  stages: { position: number; rarity: Rarity; drop: DropJson | null }[];
};

const fromJson = (j: QuestJson): Quest => ({
  ...j,
  stages: j.stages.map((s) => ({ ...s, drop: s.drop ? dropFromJson(s.drop) : null })),
});

export type { QuestPlace };

export async function getQuest(id: string): Promise<Quest | null> {
  const client = browserClient();
  if (!client) return null;
  const { data, error } = await client.rpc("public_quest", { quest_id: id });
  if (error || !data) return null;
  return fromJson(data as QuestJson);
}

/** Every active quest, and those retired in the last week. Staff only. */
export async function listQuests(): Promise<Quest[]> {
  const client = browserClient();
  if (!client) return [];
  const { data, error } = await client.rpc("staff_quests");
  if (error) throw new Error(errorText(error));
  return ((data ?? []) as QuestJson[]).map(fromJson);
}

/** Build quests now instead of waiting for the next run. Staff only. */
export async function rebuildQuests(): Promise<{ built: number; retired: number } | { error: string }> {
  const client = browserClient();
  if (!client) return { error: errorText(null) };
  const { data, error } = await client.rpc("rebuild_quests");
  if (error) return { error: errorText(error) };
  return data as { built: number; retired: number };
}

/** The stages' spots, in order, for drawing the route. */
export function routeOf(quest: Quest): LngLat[] {
  return quest.stages.flatMap((s) => (s.drop ? [{ lng: s.drop.placement.lng, lat: s.drop.placement.lat }] : []));
}

/** A box around the route, with a little room. */
export function boundsOf(points: LngLat[]): MapBounds | null {
  if (points.length === 0) return null;
  const lngs = points.map((p) => p.lng);
  const lats = points.map((p) => p.lat);
  const pad = 0.0015;
  return {
    west: Math.min(...lngs) - pad,
    south: Math.min(...lats) - pad,
    east: Math.max(...lngs) + pad,
    north: Math.max(...lats) + pad,
  };
}

/** "Within a 20-minute walk", "Up to 5 km between stages". */
export function legText(metres: number): string {
  if (metres <= 1600) return "Stages within a 20-minute walk";
  return `Up to ${Math.round(metres / 1000)} km between stages`;
}

const hh = (hour: number) => `${String(hour % 24).padStart(2, "0")}:00`;

/**
 * When every stage is open, from the 168-hour mask: "Any time", or
 * "Weekdays, 9 am to 5 pm; Saturdays, 10 am to 4 pm".
 */
export function openHoursText(mask: string): string {
  if (!mask.includes("0")) return "Any time";
  if (!mask.includes("1")) return "Never at the same time";
  // Each day's open ranges, as "start-end" in whole hours.
  const days: string[] = [];
  for (let day = 0; day < 7; day++) {
    const ranges: string[] = [];
    let start: number | null = null;
    for (let hour = 0; hour <= 24; hour++) {
      const on = hour < 24 && mask[day * 24 + hour] === "1";
      if (on && start === null) start = hour;
      if (!on && start !== null) {
        ranges.push(`${start}-${hour}`);
        start = null;
      }
    }
    days.push(ranges.join(","));
  }
  // Days with the same hours read as one group.
  const groups = new Map<string, Weekday[]>();
  days.forEach((ranges, day) => {
    if (!ranges) return;
    groups.set(ranges, [...(groups.get(ranges) ?? []), day as Weekday]);
  });
  return [...groups.entries()]
    .map(([ranges, dayList]) => {
      const hours = ranges
        .split(",")
        .map((r) => {
          const [a, b] = r.split("-").map(Number);
          return a === 0 && b === 24 ? "all day" : `${clockText(hh(a))} to ${clockText(hh(b))}`;
        })
        .join(" and ");
      return `${daysText(dayList)}, ${hours}`;
    })
    .join("; ");
}
