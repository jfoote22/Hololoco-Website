// The review queue, for staff. Every call is checked by the database: anyone who
// isn't staff gets "not_staff" back, whatever this page shows.

import { myDropFromJson, type DropJson } from "@/lib/drops/json";
import { errorText } from "@/lib/drops/mine";
import type { MyDrop } from "@/lib/drops/types";
import { browserClient } from "@/lib/supabase/browser";

export type QueueItem = MyDrop & {
  /** The owner's other drops, so a reviewer can tell a first post from a regular. */
  ownerApproved: number;
  ownerRejected: number;
  ownerSince: string | null;
};

export type Decision = "approve" | "reject" | "reopen";

/** One report as staff see it. Who sent it stays private; only whether they were signed in. */
export type ReportEntry = {
  id: number;
  reason: string;
  details: string | null;
  contact: string | null;
  at: string;
  signedIn: boolean;
};

/** A reported drop with its open reports, or a request that isn't about a drop on the map. */
export type ReportItem =
  | { kind: "drop"; drop: MyDrop; hidden: boolean; reports: ReportEntry[] }
  | { kind: "request"; drop: null; dropTitle: string | null; reports: ReportEntry[] };

export type HistoryItem = {
  id: number;
  dropId: string;
  title: string;
  action: Decision | "hide";
  reason: string | null;
  at: string;
  by: string;
  /** The drop's review status now, or null if it's been deleted. */
  review: MyDrop["review"] | null;
};

type QueueJson = DropJson & { ownerApproved: number; ownerRejected: number; ownerSince: string | null };

/** Rejection reasons a reviewer can pick. The owner sees the one chosen. */
export const REJECT_REASONS = [
  "It's offensive or hateful.",
  "It's spam.",
  "It shares someone's personal information.",
  "It's somewhere drops aren't allowed.",
] as const;

export async function listQueue(): Promise<QueueItem[]> {
  const client = browserClient();
  if (!client) return [];
  const { data, error } = await client.rpc("review_queue");
  if (error) throw new Error(errorText(error));
  return ((data ?? []) as QueueJson[]).map((j) => ({
    ...myDropFromJson(j),
    ownerApproved: j.ownerApproved,
    ownerRejected: j.ownerRejected,
    ownerSince: j.ownerSince,
  }));
}

export async function listHistory(): Promise<HistoryItem[]> {
  const client = browserClient();
  if (!client) return [];
  const { data, error } = await client.rpc("review_history", { max_results: 30 });
  if (error) throw new Error(errorText(error));
  return (data ?? []) as HistoryItem[];
}

type ReportJson =
  | { kind: "drop"; drop: DropJson; hidden: boolean; reports: ReportEntry[] }
  | { kind: "request"; drop: null; dropTitle: string | null; reports: ReportEntry[] };

export async function listReports(): Promise<ReportItem[]> {
  const client = browserClient();
  if (!client) return [];
  const { data, error } = await client.rpc("review_reports");
  if (error) throw new Error(errorText(error));
  return ((data ?? []) as ReportJson[]).map((j) =>
    j.kind === "drop" ? { ...j, drop: myDropFromJson(j.drop) } : j,
  );
}

/** Close a request that isn't about a drop on the map: handled, or dismissed. */
export async function closeReport(id: number, outcome: "resolved" | "dismissed", note?: string): Promise<string | null> {
  const client = browserClient();
  if (!client) return errorText(null);
  const { error } = await client.rpc("close_report", { report_id: id, outcome, note: note ?? null });
  return error ? errorText(error) : null;
}

export async function decide(dropId: string, decision: Decision, reason?: string): Promise<string | null> {
  const client = browserClient();
  if (!client) return errorText(null);
  const { error } = await client.rpc("review_drop", { drop_id: dropId, decision, reason: reason ?? null });
  return error ? errorText(error) : null;
}

/** "5 minutes ago", "3 hours ago", "2 days ago". */
export function timeAgo(iso: string, now = Date.now()): string {
  const minutes = Math.max(0, Math.round((now - new Date(iso).getTime()) / 60_000));
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes} minute${minutes === 1 ? "" : "s"} ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} hour${hours === 1 ? "" : "s"} ago`;
  const days = Math.round(hours / 24);
  return `${days} day${days === 1 ? "" : "s"} ago`;
}
