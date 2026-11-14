"use client";

// Report a drop (from a link with ?drop=<id>), or ask for a drop to be removed
// from a property. No account needed; a person reads every report.

import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { useEffect, useState } from "react";
import { DropThumb } from "@/components/DropThumb";
import { FocusDrop } from "@/components/map/FocusDrop";
import { choiceCard, inputClass, labelClass, primaryButton, textButton } from "@/components/ui";
import { byline } from "@/lib/drops/format";
import { dropFromJson, type DropJson } from "@/lib/drops/json";
import { sampleDrops } from "@/lib/drops/sample";
import type { PublicDrop } from "@/lib/drops/types";
import { fileReport, needsContact, needsDetails, REPORT_REASONS, type ReportReason } from "@/lib/reports";
import { browserClient } from "@/lib/supabase/browser";

type Target =
  | { state: "none" }
  | { state: "loading" }
  | { state: "sample"; drop: PublicDrop }
  | { state: "found"; drop: PublicDrop }
  | { state: "missing" };

/** Reads ?drop=<id>; a different drop gets a fresh form. */
export function ReportRoute() {
  const dropId = useSearchParams().get("drop");
  return <ReportForm key={dropId ?? "none"} dropId={dropId} />;
}

function ReportForm({ dropId }: { dropId: string | null }) {
  const [target, setTarget] = useState<Target>(() => {
    if (!dropId) return { state: "none" };
    const sample = sampleDrops.find((d) => d.id === dropId);
    return sample ? { state: "sample", drop: sample } : { state: "loading" };
  });
  const [reason, setReason] = useState<ReportReason | null>(dropId ? null : "property");
  const [details, setDetails] = useState("");
  const [contact, setContact] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<{ hidden: boolean } | null>(null);

  useEffect(() => {
    if (target.state !== "loading" || !dropId) return;
    const client = browserClient();
    if (!client) return void Promise.resolve().then(() => setTarget({ state: "missing" }));
    let cancelled = false;
    client.rpc("public_drop", { drop_id: dropId }).then(({ data }) => {
      if (cancelled) return;
      setTarget(data ? { state: "found", drop: dropFromJson(data as DropJson) } : { state: "missing" });
    });
    return () => {
      cancelled = true;
    };
  }, [target.state, dropId]);

  async function send(event: React.FormEvent) {
    event.preventDefault();
    setError(null);
    if (!reason) return setError("Choose what's wrong.");
    if (needsDetails(reason) && !details.trim())
      return setError(dropId ? "Tell us what's wrong." : "Tell us where the drop is and what it shows.");
    if (needsContact(reason) && !contact.trim()) return setError("Add an email or phone number so we can reply.");
    setBusy(true);
    const result = await fileReport(dropId, reason, details, contact);
    setBusy(false);
    if ("error" in result) return setError(result.error);
    setDone(result);
  }

  const aboutDrop = dropId !== null;
  const drop = target.state === "found" || target.state === "sample" ? target.drop : null;

  return (
    <>
      {drop && <FocusDrop drop={drop} />}

      <div className="flex flex-col gap-1">
        <h1 className="text-[22px] font-bold">{aboutDrop ? "Report a drop" : "Ask for a drop to be removed"}</h1>
        <p className="text-sm text-muted">
          {aboutDrop
            ? "A person reads every report, usually within a day. You don't need an account."
            : "If a drop is on your property or somewhere it shouldn't be, tell us where. You don't need an account, and a person reads every request, usually within a day."}
        </p>
      </div>

      {drop && (
        <div className="flex items-center gap-3 rounded-lg border border-line p-3">
          <DropThumb drop={drop} />
          <div className="flex min-w-0 flex-col">
            <span className="truncate font-semibold">{drop.title}</span>
            <span className="text-[13px] text-muted">{byline(drop)}</span>
          </div>
        </div>
      )}

      {target.state === "loading" && <p className="text-sm text-muted">Loading the drop…</p>}
      {target.state === "missing" && (
        <p className="rounded-lg bg-wash px-3 py-2.5 text-sm">
          That drop isn&apos;t on the map anymore, so there&apos;s nothing to report.{" "}
          <Link href="/report" className="font-medium text-accent hover:underline">
            Ask for a removal instead
          </Link>
        </p>
      )}
      {target.state === "sample" && (
        <p className="rounded-lg bg-wash px-3 py-2.5 text-sm">This is a sample drop for testing, so there&apos;s nothing to report.</p>
      )}

      {done ? (
        <div role="status" className="flex flex-col gap-3 rounded-lg bg-accent-wash px-3 py-3 text-sm">
          <p>
            <b>Thanks.</b> A person will look at it, usually within a day.
            {done.hidden && " We've hidden it from the map until they do."}
          </p>
          <Link href="/" className={`${textButton} self-start`}>
            Back to the map
          </Link>
        </div>
      ) : (
        (target.state === "none" || target.state === "found") && (
          <form onSubmit={send} className="flex flex-col gap-4">
            {aboutDrop && (
              <fieldset className="flex flex-col gap-2">
                <legend className="mb-2 text-sm font-semibold">What&apos;s wrong?</legend>
                {REPORT_REASONS.map((r) => (
                  <label key={r.id} className={`${choiceCard} p-2.5`}>
                    <input
                      type="radio"
                      name="reason"
                      checked={reason === r.id}
                      onChange={() => setReason(r.id)}
                      className="mt-0.5 accent-accent"
                    />
                    <span className="text-sm">
                      {r.label}
                      {r.note && <span className="block text-[13px] text-muted">{r.note}</span>}
                    </span>
                  </label>
                ))}
              </fieldset>
            )}

            <label className={labelClass}>
              {!aboutDrop
                ? "Where is it, and what does it show?"
                : reason && needsDetails(reason)
                  ? "What's wrong?"
                  : "Anything else we should know? (optional)"}
              <textarea
                value={details}
                rows={3}
                maxLength={1000}
                onChange={(event) => setDetails(event.target.value)}
                className={`${inputClass} py-2 leading-normal`}
              />
            </label>

            <label className={labelClass}>
              {reason && needsContact(reason) ? "Email or phone, so we can reply" : "Email or phone, if you'd like a reply (optional)"}
              <input
                value={contact}
                maxLength={200}
                autoComplete="email"
                onChange={(event) => setContact(event.target.value)}
                className={inputClass}
              />
              <span className="text-xs font-normal text-muted">Only Hololoco staff see it, and only to reply about this.</span>
            </label>

            {error && (
              <p role="alert" className="text-sm text-rejected">
                {error}
              </p>
            )}

            <button type="submit" disabled={busy} className={primaryButton}>
              {busy ? "Sending…" : aboutDrop ? "Send report" : "Send request"}
            </button>
          </form>
        )
      )}
    </>
  );
}
