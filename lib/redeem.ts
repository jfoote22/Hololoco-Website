// Redeeming at the counter. A player taps Redeem in the app and gets a 6-digit
// code for 10 minutes; the business types it in here. Only the business that
// made the offer can confirm its codes, and each works once.

import { browserClient } from "@/lib/supabase/browser";
import { errorText } from "@/lib/drops/mine";

export type Redeemed = { title: string; savings: string | null; terms: string | null; player: string; at: string };

export async function confirmRedemption(code: string): Promise<Redeemed | { error: string }> {
  const client = browserClient();
  if (!client) return { error: "Redeeming isn't switched on here yet." };
  const digits = code.replace(/\D/g, "");
  if (digits.length !== 6) return { error: "A code has 6 digits." };
  const { data, error } = await client.rpc("confirm_redemption", { code: digits });
  if (error) {
    const message = error.message ?? "";
    if (message.includes("code_not_found"))
      return {
        error:
          "That code isn't one of yours, has been used, or ran out. Codes last 10 minutes: ask them to tap Redeem again.",
      };
    if (message.includes("bad_code")) return { error: "A code has 6 digits." };
    if (message.includes("Could not find the function")) return { error: "Redeeming isn't switched on here yet." };
    return { error: errorText(error) };
  }
  return data as Redeemed;
}

export type Redemption = { at: string; title: string; savings: string | null; player: string };

export async function recentRedemptions(): Promise<Redemption[]> {
  const client = browserClient();
  if (!client) return [];
  const { data, error } = await client.rpc("recent_redemptions");
  if (error) return [];
  return (data ?? []) as Redemption[];
}
