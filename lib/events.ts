// Events (the Events plan): a business links its own drops into a hunt (any
// order) or a trail (in order) for a set time. Players play them in the app.

import { browserClient } from "@/lib/supabase/browser";
import { errorText } from "@/lib/drops/mine";

export type EventFormat = "hunt" | "trail";

export type BusinessEvent = {
  id: string;
  title: string;
  description: string;
  format: EventFormat;
  startsAt: string;
  endsAt: string;
  live: boolean;
  paused: boolean;
  stopXp: number;
  bonusXp: number;
  bonusPoints: number;
  reward: { dropId: string; title: string; savings: string; remaining: number } | null;
  stops: { position: number; dropId: string; drop: { title: string } | null }[];
  started: number;
  finished: number;
};

export type EventInput = {
  id?: string;
  title: string;
  description: string;
  format: EventFormat;
  /** ISO times. */
  startsAt: string;
  endsAt: string;
  stopXp: number;
  bonusXp: number;
  bonusPoints: number;
  rewardDropId: string | null;
  paused: boolean;
  /** Drop ids, in order. */
  stops: string[];
};

export const eventLimits = { minStops: 2, maxStops: 20, maxStopXp: 100, maxBonusXp: 1000, maxBonusPoints: 500, maxDays: 92 };

export async function listMyEvents(): Promise<BusinessEvent[]> {
  const client = browserClient();
  if (!client) return [];
  const { data, error } = await client.rpc("my_events");
  if (error) throw new Error(eventErrorText(error));
  return (data ?? []) as BusinessEvent[];
}

export async function saveEvent(input: EventInput): Promise<{ id: string } | { error: string }> {
  const client = browserClient();
  if (!client) return { error: "Events aren't switched on here yet." };
  const { data, error } = await client.rpc("save_event", { payload: input });
  if (error || typeof data !== "string") return { error: eventErrorText(error) };
  return { id: data };
}

export async function deleteEvent(id: string): Promise<string | null> {
  const client = browserClient();
  if (!client) return null;
  const { error } = await client.rpc("delete_event", { event_id: id });
  return error ? eventErrorText(error) : null;
}

export function eventErrorText(error: { message?: string; code?: string } | null): string {
  const message = error?.message ?? "";
  if (message.includes("plan_events")) return "Events come with the Events plan.";
  if (message.includes("event_stops")) return `Choose ${eventLimits.minStops} to ${eventLimits.maxStops} of your own drops as stops.`;
  if (message.includes("event_reward")) return "The reward has to be one of your offers.";
  if (message.includes("limit_events")) return "You can have 20 events coming up or on at once.";
  if (message.includes("account_under_review"))
    return "While a person is checking your drops, you can't make events. Try again once that's done.";
  if (message.includes("event_window")) return `An event ends after it starts, and lasts at most ${eventLimits.maxDays} days.`;
  if (message.includes("Could not find the function")) return "Events aren't switched on here yet.";
  return errorText(error);
}
