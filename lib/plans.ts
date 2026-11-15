// Plans: what each account can add, read and asked for from the browser. The
// database enforces every limit (the plans migration); this only shows them.

import { browserClient } from "@/lib/supabase/browser";
import { errorText } from "@/lib/drops/mine";

export type PlanId = "free" | "plus" | "business" | "events";

export type Plan = {
  id: PlanId;
  name: string;
  blurb: string;
  maxDrops: number;
  dailyDrops: number;
  models: boolean;
  offers: boolean;
  events: boolean;
  /** US cents a month, or null while there's no price yet. */
  monthlyCents: number | null;
};

export type PlanRequest = {
  id: number;
  plan: PlanId;
  status: "open" | "granted" | "declined" | "withdrawn";
  note: string;
  answer: string | null;
  at: string;
  decidedAt: string | null;
};

export type MyPlan = {
  plan: PlanId;
  until: string | null;
  staff: boolean;
  drops: number;
  dropsToday: number;
  /** The open request, or one decided in the last two weeks. */
  request: PlanRequest | null;
  plans: Plan[];
};

/** What the account can do. Staff can do everything. */
export type Allowed = { offers: boolean; models: boolean; events: boolean };

export function allowed(plan: MyPlan | null): Allowed {
  if (!plan) return { offers: true, models: true, events: false };
  if (plan.staff) return { offers: true, models: true, events: true };
  const current = plan.plans.find((p) => p.id === plan.plan);
  return { offers: !!current?.offers, models: !!current?.models, events: !!current?.events };
}

/** The cheapest plan that allows something. */
export function planFor(plan: MyPlan | null, need: keyof Allowed): Plan | null {
  return plan?.plans.find((p) => p[need]) ?? null;
}

export function priceText(plan: Plan): string {
  if (plan.monthlyCents === 0) return "Free";
  if (plan.monthlyCents === null) return "Free while Hololoco is in testing";
  return `$${(plan.monthlyCents / 100).toFixed(plan.monthlyCents % 100 === 0 ? 0 : 2)} a month`;
}

/** Null when signed out, or when the database doesn't have plans yet. */
export async function getMyPlan(): Promise<MyPlan | null> {
  const client = browserClient();
  if (!client) return null;
  const { data, error } = await client.rpc("my_plan");
  if (error || !data) return null;
  return data as MyPlan;
}

export async function requestPlan(plan: PlanId, note: string): Promise<string | null> {
  const client = browserClient();
  if (!client) return "Plans aren't switched on here yet.";
  const { error } = await client.rpc("request_plan", { plan, note: note.trim() });
  return error ? planErrorText(error) : null;
}

export async function withdrawPlanRequest(): Promise<string | null> {
  const client = browserClient();
  if (!client) return null;
  const { error } = await client.rpc("withdraw_plan_request");
  return error ? planErrorText(error) : null;
}

/** Staff: a request waiting for an answer. */
export type QueuedPlanRequest = {
  id: number;
  plan: PlanId;
  note: string;
  at: string;
  user: { id: string; name: string; email: string | null; plan: PlanId; since: string; strikes: number; drops: number };
};

export async function listPlanRequests(): Promise<QueuedPlanRequest[]> {
  const client = browserClient();
  if (!client) return [];
  const { data, error } = await client.rpc("plan_requests_queue");
  if (error) throw new Error(planErrorText(error));
  return (data ?? []) as QueuedPlanRequest[];
}

export async function decidePlanRequest(id: number, grant: boolean, answer: string): Promise<string | null> {
  const client = browserClient();
  if (!client) return null;
  const { error } = await client.rpc("decide_plan_request", {
    request_id: id,
    grant_it: grant,
    answer: answer.trim() || null,
  });
  return error ? planErrorText(error) : null;
}

export const planNames: Record<PlanId, string> = { free: "Free", plus: "Plus", business: "Business", events: "Events" };

function planErrorText(error: { message?: string; code?: string }): string {
  const message = error.message ?? "";
  if (message.includes("note_needed")) return "Say a little about what you'll use it for.";
  if (message.includes("already_on_plan")) return "You're on that plan already.";
  if (message.includes("limit_requests")) return "That's a lot of requests for one day. Try again tomorrow.";
  if (message.includes("bad_plan")) return "That isn't a plan you can ask for.";
  if (message.includes("Could not find the function")) return "Plans aren't switched on here yet.";
  return errorText(error);
}
