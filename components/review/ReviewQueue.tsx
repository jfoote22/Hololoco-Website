"use client";

// Staff review: reports first, then drops waiting for review, oldest first.
// Approve or keep, or don't approve / take down with a reason the owner sees.
// Every decision is logged and can be undone.

import { useEffect, useState } from "react";
import { dropChanged } from "@/app/actions";
import { SignIn } from "@/components/auth/SignIn";
import { useSession } from "@/components/auth/session";
import { DropThumb } from "@/components/DropThumb";
import { useMap } from "@/components/map/MapProvider";
import { choiceCard, inputClass, labelClass, textButton } from "@/components/ui";
import { timingText, typeLabel } from "@/lib/drops/format";
import type { MyDrop } from "@/lib/drops/types";
import { reasonLabel } from "@/lib/reports";
import {
  closeReport,
  decide,
  listHistory,
  listQueue,
  listReports,
  REJECT_REASONS,
  timeAgo,
  type Decision,
  type HistoryItem,
  type QueueItem,
  type ReportEntry,
  type ReportItem,
} from "@/lib/review";

const OTHER = "other";
const REASON_MAX = 300;

type Loaded = {
  userId: string;
  queue: QueueItem[] | null;
  reports: ReportItem[] | null;
  history: HistoryItem[] | null;
  error: string | null;
};

/** A message about the last action, kept for the account that took it. */
type Notice = { userId: string | null; text: string; undo?: { id: string; title: string } };

function ownerLine(item: QueueItem): string {
  if (item.ownerApproved === 0 && item.ownerRejected === 0) return "their first drop";
  const approved = `${item.ownerApproved} approved before`;
  return item.ownerRejected ? `${approved}, ${item.ownerRejected} not approved` : approved;
}

function factsLine(drop: MyDrop): string {
  const { size, height } = drop.placement;
  const parts = [`${size} m across`, height === 0 ? "on the ground" : `${height} m up`];
  const when = timingText(drop.timing);
  if (when) parts.push(when);
  if (drop.audience === "link") parts.push("link only");
  return parts.join(" · ");
}

const ACTION_WORDS: Record<HistoryItem["action"], string> = {
  approve: "Approved",
  reject: "Not approved",
  reopen: "Back in the queue",
  hide: "Hidden after a report",
};

export function ReviewQueue() {
  const session = useSession();
  const { focus, setSheet, reload } = useMap();
  const userId = session.status === "signed-in" ? session.user.id : null;
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  const [version, setVersion] = useState(0);
  const [busy, setBusy] = useState<string | null>(null);
  const [notice, setNotice] = useState<Notice | null>(null);

  useEffect(() => {
    if (!userId) return;
    let cancelled = false;
    Promise.all([listReports(), listQueue(), listHistory()])
      .then(([reports, queue, history]) => !cancelled && setLoaded({ userId, reports, queue, history, error: null }))
      .catch(
        (error: Error) =>
          !cancelled && setLoaded({ userId, reports: null, queue: null, history: null, error: error.message }),
      );
    return () => {
      cancelled = true;
    };
  }, [userId, version]);

  const current = loaded?.userId === userId ? loaded : null;

  async function decideDrop(item: { id: string; title: string }, decision: Decision, reason: string | undefined, reported: boolean) {
    setBusy(item.id);
    const failed = await decide(item.id, decision, reason);
    setBusy(null);
    if (failed) return setNotice({ userId, text: failed });
    const text =
      decision === "approve"
        ? reported
          ? `Kept "${item.title}". Its reports are closed.`
          : `Approved "${item.title}". It's public now.`
        : decision === "reject"
          ? reported
            ? `Took down "${item.title}". Its owner can see why.`
            : `"${item.title}" wasn't approved. Its owner can see why.`
          : `"${item.title}" is back in the queue.`;
    setNotice({ userId, text, undo: decision === "reopen" ? undefined : item });
    void dropChanged(item.id);
    reload();
    setVersion((v) => v + 1);
  }

  async function closeRequest(id: number, outcome: "resolved" | "dismissed") {
    setBusy(String(id));
    const failed = await closeReport(id, outcome);
    setBusy(null);
    if (failed) return setNotice({ userId, text: failed });
    setNotice({ userId, text: outcome === "resolved" ? "Marked as handled." : "Dismissed." });
    setVersion((v) => v + 1);
  }

  function showOnMap(drop: MyDrop) {
    focus(drop);
    setSheet("peek");
  }

  return (
    <>
      <div className="flex flex-col gap-1">
        <h1 className="text-[22px] font-bold">Review</h1>
        <p className="text-sm text-muted">
          Reports come first, then each new account&apos;s first drop. Keep or approve anything that follows the content
          rules; if something doesn&apos;t, say why. The owner sees the reason.
        </p>
      </div>

      {session.status === "loading" && <p className="text-sm text-muted">Loading…</p>}
      {session.status === "signed-out" && <SignIn next="/review" lead="Sign in with a staff account." />}

      {userId && !current && <p className="text-sm text-muted">Loading…</p>}
      {current?.error && (
        <p className="rounded-lg bg-wash px-3 py-2.5 text-sm">
          {current.error.includes("staff") ? "This page is for Hololoco staff." : current.error}
        </p>
      )}

      {notice && notice.userId === userId && (
        <p role="status" className="flex flex-wrap items-center gap-x-3 rounded-lg bg-accent-wash px-3 py-1.5 text-sm">
          <span className="py-1">{notice.text}</span>
          {notice.undo && (
            <button
              type="button"
              onClick={() => notice.undo && decideDrop(notice.undo, "reopen", undefined, false)}
              className={textButton}
            >
              Undo
            </button>
          )}
        </p>
      )}

      {current?.reports && (
        <section className="flex flex-col gap-2" aria-labelledby="reports-heading">
          <h2 id="reports-heading" className="text-base font-semibold">
            {current.reports.length === 0 ? "No open reports" : `Reports (${current.reports.length})`}
          </h2>
          {current.reports.length > 0 && (
            <ul className="flex flex-col divide-y divide-line">
              {current.reports.map((item) =>
                item.kind === "drop" ? (
                  <li key={`d-${item.drop.id}`} className="flex flex-col gap-2 py-3">
                    <div className="flex items-start gap-3">
                      <DropThumb drop={item.drop} />
                      <div className="flex min-w-0 flex-col">
                        <span className="font-semibold break-words">{item.drop.title}</span>
                        <span className="text-[13px] text-muted">
                          {typeLabel[item.drop.type]} from {item.drop.owner.name}
                        </span>
                        <span className={`text-[13px] font-semibold ${item.hidden ? "text-review" : "text-muted"}`}>
                          {item.hidden ? "Hidden from the map until you decide" : "Still on the map"}
                        </span>
                      </div>
                    </div>
                    {item.drop.description && (
                      <p className="text-sm break-words whitespace-pre-line">{item.drop.description}</p>
                    )}
                    <Reports reports={item.reports} />
                    <Decide
                      busy={busy === item.drop.id}
                      approveLabel="Keep it"
                      rejectLabel="Take it down"
                      onApprove={() => decideDrop(item.drop, "approve", undefined, true)}
                      onReject={(reason) => decideDrop(item.drop, "reject", reason, true)}
                      onShow={() => showOnMap(item.drop)}
                    />
                  </li>
                ) : (
                  <li key={`r-${item.reports[0].id}`} className="flex flex-col gap-2 py-3">
                    <span className="font-semibold">
                      {item.dropTitle ? `About a drop since deleted: ${item.dropTitle}` : "Removal request"}
                    </span>
                    <Reports reports={item.reports} />
                    <div className="flex flex-wrap gap-2">
                      <button
                        type="button"
                        disabled={busy === String(item.reports[0].id)}
                        onClick={() => closeRequest(item.reports[0].id, "resolved")}
                        className="min-h-11 rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-strong disabled:opacity-60"
                      >
                        Mark as handled
                      </button>
                      <button
                        type="button"
                        disabled={busy === String(item.reports[0].id)}
                        onClick={() => closeRequest(item.reports[0].id, "dismissed")}
                        className="min-h-11 rounded-lg border border-line px-4 text-sm font-semibold hover:bg-wash disabled:opacity-60"
                      >
                        Dismiss
                      </button>
                    </div>
                  </li>
                ),
              )}
            </ul>
          )}
        </section>
      )}

      {current?.queue && (
        <section className="flex flex-col gap-2 border-t border-line pt-3" aria-labelledby="queue-heading">
          <h2 id="queue-heading" className="text-base font-semibold">
            {current.queue.length === 0 ? "Nothing waiting for review" : `Waiting for review (${current.queue.length})`}
          </h2>
          {current.queue.length === 0 && <p className="text-sm text-muted">New accounts&apos; first drops show up here.</p>}
          <ul className="flex flex-col divide-y divide-line">
            {current.queue.map((item) => (
              <li key={item.id} className="flex flex-col gap-2 py-3">
                <div className="flex items-start gap-3">
                  <DropThumb drop={item} />
                  <div className="flex min-w-0 flex-col">
                    <span className="font-semibold break-words">{item.title}</span>
                    <span className="text-[13px] text-muted">
                      {typeLabel[item.type]} from {item.owner.name}, {ownerLine(item)}
                    </span>
                    <span className="text-[13px] text-muted">Added {timeAgo(item.createdAt)}</span>
                  </div>
                </div>
                {item.description && <p className="text-sm break-words whitespace-pre-line">{item.description}</p>}
                <p className="text-[13px] text-muted">{factsLine(item)}</p>
                <Decide
                  busy={busy === item.id}
                  approveLabel="Approve"
                  rejectLabel="Don't approve"
                  onApprove={() => decideDrop(item, "approve", undefined, false)}
                  onReject={(reason) => decideDrop(item, "reject", reason, false)}
                  onShow={() => showOnMap(item)}
                />
              </li>
            ))}
          </ul>
        </section>
      )}

      {current?.history && current.history.length > 0 && (
        <section className="flex flex-col gap-2 border-t border-line pt-3" aria-labelledby="history-heading">
          <h2 id="history-heading" className="text-base font-semibold">
            Recent decisions
          </h2>
          <ul className="flex flex-col gap-2">
            {current.history.map((event, i) => {
              const latest = current.history?.findIndex((e) => e.dropId === event.dropId) === i;
              const canReopen =
                latest &&
                (event.action === "approve" || event.action === "reject") &&
                (event.review === "approved" || event.review === "rejected");
              return (
                <li key={event.id} className="flex flex-col text-sm">
                  <span>
                    <b className="font-semibold">{ACTION_WORDS[event.action]}</b>: {event.title}
                    {event.review === null && <span className="text-muted"> (since deleted)</span>}
                  </span>
                  {event.reason && (
                    <span className="text-[13px] text-muted">
                      {event.action === "hide"
                        ? `Reported as: ${reasonLabel(event.reason.replace(/^Hidden after a report: /, ""))}`
                        : event.reason}
                    </span>
                  )}
                  <span className="flex flex-wrap items-center gap-x-2 text-[13px] text-muted">
                    {event.action === "hide" ? "Automatically" : event.by}, {timeAgo(event.at)}
                    {canReopen && (
                      <button
                        type="button"
                        disabled={busy === event.dropId}
                        onClick={() => decideDrop({ id: event.dropId, title: event.title }, "reopen", undefined, false)}
                        className={`${textButton} min-h-9 text-[13px]`}
                      >
                        Put back in the queue
                      </button>
                    )}
                  </span>
                </li>
              );
            })}
          </ul>
        </section>
      )}
    </>
  );
}

function Reports({ reports }: { reports: ReportEntry[] }) {
  return (
    <ul className="flex flex-col gap-1.5 rounded-lg bg-wash px-3 py-2">
      {reports.map((r) => (
        <li key={r.id} className="flex flex-col text-sm">
          <span>
            <b className="font-semibold">{reasonLabel(r.reason)}</b>
            <span className="text-[13px] text-muted">
              {" "}
              · {timeAgo(r.at)} · {r.signedIn ? "signed in" : "no account"}
            </span>
          </span>
          {r.details && <span className="break-words whitespace-pre-line">{r.details}</span>}
          {r.contact && <span className="text-[13px] text-muted break-all">Reply to: {r.contact}</span>}
        </li>
      ))}
    </ul>
  );
}

/** Approve (or keep), or don't (or take it down) with a reason the owner sees. */
function Decide({
  busy,
  approveLabel,
  rejectLabel,
  onApprove,
  onReject,
  onShow,
}: {
  busy: boolean;
  approveLabel: string;
  rejectLabel: string;
  onApprove: () => void;
  onReject: (reason: string) => void;
  onShow: () => void;
}) {
  const [open, setOpen] = useState(false);
  const [choice, setChoice] = useState<string>(REJECT_REASONS[0]);
  const [note, setNote] = useState("");
  const [problem, setProblem] = useState<string | null>(null);

  if (!open) {
    return (
      <div className="flex flex-wrap items-center gap-2">
        <button
          type="button"
          disabled={busy}
          onClick={onApprove}
          className="min-h-11 rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-strong disabled:opacity-60"
        >
          {approveLabel}
        </button>
        <button
          type="button"
          disabled={busy}
          onClick={() => setOpen(true)}
          className="min-h-11 rounded-lg border border-line px-4 text-sm font-semibold hover:bg-wash disabled:opacity-60"
        >
          {rejectLabel}
        </button>
        <button type="button" onClick={onShow} className={textButton}>
          Show on the map
        </button>
      </div>
    );
  }

  return (
    <form
      className="flex flex-col gap-2 rounded-lg border border-line p-3"
      onSubmit={(event) => {
        event.preventDefault();
        const extra = note.trim();
        const reason = choice === OTHER ? extra : extra ? `${choice} ${extra}` : choice;
        if (!reason) return setProblem("Say what's wrong. The owner sees the reason.");
        onReject(reason.slice(0, REASON_MAX));
      }}
    >
      <fieldset className="flex flex-col gap-2">
        <legend className="mb-1 text-sm font-semibold">Why?</legend>
        {[...REJECT_REASONS, OTHER].map((reason) => (
          <label key={reason} className={`${choiceCard} p-2.5`}>
            <input
              type="radio"
              name="decision-reason"
              checked={choice === reason}
              onChange={() => setChoice(reason)}
              className="mt-0.5 accent-accent"
            />
            <span className="text-sm">{reason === OTHER ? "Something else" : reason}</span>
          </label>
        ))}
      </fieldset>
      <label className={labelClass}>
        {choice === OTHER ? "What's wrong" : "Note for the owner (optional)"}
        <textarea
          value={note}
          rows={2}
          maxLength={200}
          onChange={(event) => setNote(event.target.value)}
          className={`${inputClass} py-2 leading-normal`}
        />
      </label>
      {problem && (
        <p role="alert" className="text-sm text-rejected">
          {problem}
        </p>
      )}
      <div className="flex gap-2">
        <button
          type="submit"
          disabled={busy}
          className="min-h-11 flex-1 rounded-lg bg-rejected px-3 text-sm font-semibold text-white disabled:opacity-60"
        >
          {rejectLabel}
        </button>
        <button
          type="button"
          onClick={() => setOpen(false)}
          className="min-h-11 flex-1 rounded-lg border border-line px-3 text-sm font-semibold hover:bg-wash"
        >
          Cancel
        </button>
      </div>
    </form>
  );
}
