// Reporting a drop, or asking for one to be removed. No account needed. The
// database decides what happens: it hides a drop after a serious report or after
// reports from three different people, and only staff can read reports.

import { browserClient } from "@/lib/supabase/browser";

export type ReportReason = "offensive" | "spam" | "personal" | "unsafe" | "property" | "copyright" | "other";

export const REPORT_REASONS: { id: ReportReason; label: string; note?: string }[] = [
  { id: "offensive", label: "It's offensive or hateful" },
  { id: "spam", label: "It's spam or a scam" },
  { id: "personal", label: "It shares someone's personal information", note: "We hide it right away while we check." },
  { id: "unsafe", label: "It's dangerous or illegal", note: "We hide it right away while we check." },
  { id: "property", label: "It's on my property and I want it removed" },
  { id: "copyright", label: "It uses my work without permission" },
  { id: "other", label: "Something else" },
];

export function reasonLabel(id: string): string {
  return REPORT_REASONS.find((r) => r.id === id)?.label ?? id;
}

/** Details are needed to act on these. */
export const needsDetails = (reason: ReportReason) => reason === "other" || reason === "property";
/** A way to reply is needed for these. */
export const needsContact = (reason: ReportReason) => reason === "property" || reason === "copyright";

function errorText(message: string): string {
  if (message.includes("details_needed")) return "Tell us a little more so a person can act on it.";
  if (message.includes("contact_needed")) return "Add an email or phone number so we can reply.";
  if (message.includes("limit_reports")) return "You've sent a lot of reports today. Try again tomorrow.";
  if (message.includes("not_found")) return "That drop isn't on the map anymore.";
  if (message.includes("Failed to fetch") || message.includes("NetworkError"))
    return "Couldn't reach Hololoco. Check your connection and try again.";
  return "Couldn't send the report. Try again in a moment.";
}

export async function fileReport(
  dropId: string | null,
  reason: ReportReason,
  details: string,
  contact: string,
): Promise<{ hidden: boolean } | { error: string }> {
  const client = browserClient();
  if (!client) return { error: "Reporting isn't switched on here yet." };
  const { data, error } = await client.rpc("file_report", {
    drop_id: dropId,
    reason,
    details: details.trim() || null,
    contact: contact.trim() || null,
  });
  if (error) return { error: errorText(error.message ?? "") };
  return { hidden: Boolean((data as { hidden?: boolean } | null)?.hidden) };
}
