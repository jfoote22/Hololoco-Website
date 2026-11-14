// The signed-in person's own drops and profile, read and changed from the browser.
// The database checks every call (row-level security and the rules in the first
// migration); these functions only turn its answers into plain words.

import { browserClient } from "@/lib/supabase/browser";
import { myDropFromJson, type DropJson } from "./json";
import { limits } from "./limits";
import type { DropInput, MyDrop, Rarity, Review } from "./types";

export type Profile = { displayName: string | null; adultConfirmed: boolean; isStaff: boolean };

type DbError = { message?: string; code?: string } | null;

const NOT_SET_UP = "Adding to the map isn't switched on here yet.";

/** Plain words for whatever the database said no to. */
export function errorText(error: DbError): string {
  const message = error?.message ?? "";
  if (message.includes("profile_incomplete"))
    return "Add the name shown on your drops and confirm you're 18 or older.";
  if (message.includes("limit_total"))
    return `You can have ${limits.individualLiveDrops} drops at a time. Delete one in Your drops to add another.`;
  if (message.includes("limit_daily"))
    return `You can add ${limits.individualNewPerDay} drops a day. Try again tomorrow.`;
  if (message.includes("limit_crowded"))
    return `This spot already has ${limits.crowdingMaxDrops} drops within ${limits.crowdingRadiusMetres} m. Try somewhere a little further away.`;
  if (message.includes("schedule_empty")) return "Add at least one set of hours, or choose Always.";
  if (message.includes("offer_incomplete")) return "Say what people get with the offer.";
  if (message.includes("account_suspended"))
    return "Your account is suspended, so you can't add or change drops.";
  if (message.includes("ends_after_start") || message.includes("once_ends_after_start"))
    return "The end has to be after the start.";
  if (message.includes("not_found")) return "That drop isn't one of yours, or it's been deleted.";
  if (message.includes("not_staff")) return "Only Hololoco staff can do that.";
  if (message.includes("asset_rejected")) return "That photo or model wasn't approved. Choose another look.";
  if (message.includes("asset_not_found")) return "That photo or model isn't available anymore. Choose another look.";
  if (message.includes("asset_not_published")) return "Its photo or model hasn't been published yet.";
  if (message.includes("reason_needed")) return "Say why it isn't approved. The owner sees the reason.";
  if (message.includes("bad_time_zone")) return "That time zone isn't one we know. Pick another.";
  if (error?.code === "23514") return "Something is outside the limits. Check the title, description, size and height.";
  if (error?.code === "PGRST301" || message.includes("JWT")) return "Your sign-in has expired. Sign in again.";
  if (message.includes("Failed to fetch") || message.includes("NetworkError"))
    return "Couldn't reach Hololoco. Check your connection and try again.";
  return "Something went wrong. Try again in a moment.";
}

export async function getProfile(userId: string): Promise<Profile | null> {
  const client = browserClient();
  if (!client) return null;
  const { data, error } = await client
    .from("profiles")
    .select("display_name, adult_confirmed_at, is_staff")
    .eq("id", userId)
    .maybeSingle();
  if (error || !data) return null;
  return {
    displayName: data.display_name,
    adultConfirmed: data.adult_confirmed_at !== null,
    isStaff: data.is_staff === true,
  };
}

/** Saves the name shown on their drops and records that they confirmed they're 18 or older. */
export async function saveProfile(userId: string, displayName: string): Promise<string | null> {
  const client = browserClient();
  if (!client) return NOT_SET_UP;
  const { error } = await client
    .from("profiles")
    .update({ display_name: displayName.trim(), adult_confirmed_at: new Date().toISOString() })
    .eq("id", userId);
  return error ? errorText(error) : null;
}

/**
 * good: drops go live at once. review: a complaint is open or a drop was taken
 * down, so new drops and changes wait for a person. suspended: three strikes.
 */
export type Standing = { standing: "good" | "review" | "suspended"; strikes: number };

export async function getStanding(): Promise<Standing | null> {
  const client = browserClient();
  if (!client) return null;
  const { data, error } = await client.rpc("my_standing");
  if (error || !data) return null;
  return data as Standing;
}

export async function listMyDrops(): Promise<MyDrop[]> {
  const client = browserClient();
  if (!client) return [];
  const { data, error } = await client.rpc("my_drops");
  if (error) throw new Error(errorText(error));
  return ((data ?? []) as DropJson[]).map(myDropFromJson);
}

export async function saveDrop(input: DropInput): Promise<{ id: string; review: Review } | { error: string }> {
  const client = browserClient();
  if (!client) return { error: NOT_SET_UP };
  const { data: id, error } = await client.rpc("save_drop", { payload: input });
  if (error || typeof id !== "string") return { error: errorText(error) };
  const { data } = await client.from("drops").select("review").eq("id", id).maybeSingle();
  return { id, review: (data?.review as Review | undefined) ?? "pending" };
}

/** Changes how rare an offer is. The database sends it back for the automatic check. */
export async function setRarity(id: string, rarity: Rarity): Promise<string | null> {
  const client = browserClient();
  if (!client) return NOT_SET_UP;
  const { error } = await client.from("offers").update({ rarity }).eq("drop_id", id);
  return error ? errorText(error) : null;
}

export async function setPaused(id: string, paused: boolean): Promise<string | null> {
  const client = browserClient();
  if (!client) return NOT_SET_UP;
  const { error } = await client.from("drops").update({ paused }).eq("id", id);
  return error ? errorText(error) : null;
}

export async function deleteDrop(id: string): Promise<string | null> {
  const client = browserClient();
  if (!client) return NOT_SET_UP;
  const { error } = await client.from("drops").delete().eq("id", id);
  return error ? errorText(error) : null;
}
