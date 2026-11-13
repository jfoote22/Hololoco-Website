"use client";

// The review queue: drops waiting for a person to check them, oldest first.
// Approve, or reject with a reason the owner sees. Every decision is logged and
// can be undone from the list of recent decisions.

import { useEffect, useState } from "react";
import { dropChanged } from "@/app/actions";
import { SignIn } from "@/components/auth/SignIn";
import { useSession } from "@/components/auth/session";
import { DropThumb } from "@/components/DropThumb";
import { useMap } from "@/components/map/MapProvider";
import { choiceCard, inputClass, labelClass, textButton } from "@/components/ui";
import { timingText, typeLabel } from "@/lib/drops/format";
import { decide, listHistory, listQueue, REJECT_REASONS, timeAgo, type HistoryItem, type QueueItem } from "@/lib/review";

const OTHER = "other";
const REASON_MAX = 300;

type Loaded = { userId: string; queue: QueueItem[] | null; history: HistoryItem[] | null; error: string | null };
/** A message about the last action, kept for the account that took it. */
type Notice = { userId: string | null; text: string; undo?: { id: string; title: string } };

function ownerLine(item: QueueItem): string {
  if (item.ownerApproved === 0 && item.ownerRejected === 0) return "their first drop";
  const approved = `${item.ownerApproved} approved before`;
  return item.ownerRejected ? `${approved}, ${item.ownerRejected} not approved` : approved;
}

function factsLine(item: QueueItem): string {
  const { size, height } = item.placement;
  const parts = [`${size} m across`, height === 0 ? "on the ground" : `${height} m up`];
  const when = timingText(item.timing);
  if (when) parts.push(when);
  if (item.audience === "link") parts.push("link only");
  return parts.join(" · ");
}

const ACTION_WORDS: Record<HistoryItem["action"], string> = {
  approve: "Approved",
  reject: "Not approved",
  reopen: "Back in the queue",
};

export function ReviewQueue() {
  const session = useSession();
  const { focus, setSheet, reload } = useMap();
  const userId = session.status === "signed-in" ? session.user.id : null;
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  const [version, setVersion] = useState(0);
  const [rejecting, setRejecting] = useState<string | null>(null);
  const [choice, setChoice] = useState<string>(REJECT_REASONS[0]);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [notice, setNotice] = useState<Notice | null>(null);

  useEffect(() => {
    if (!userId) return;
    let cancelled = false;
    Promise.all([listQueue(), listHistory()])
      .then(([queue, history]) => !cancelled && setLoaded({ userId, queue, history, error: null }))
      .catch((error: Error) => !cancelled && setLoaded({ userId, queue: null, history: null, error: error.message }));
    return () => {
      cancelled = true;
    };
  }, [userId, version]);

  const current = loaded?.userId === userId ? loaded : null;

  function openReject(id: string) {
    setRejecting(id);
    setChoice(REJECT_REASONS[0]);
    setNote("");
  }

  function reasonFor(): string | null {
    const extra = note.trim();
    if (choice === OTHER) return extra || null;
    return extra ? `${choice} ${extra}` : choice;
  }

  async function act(item: { id: string; title: string }, decision: "approve" | "reject" | "reopen", reason?: string) {
    setBusy(item.id);
    const failed = await decide(item.id, decision, reason);
    setBusy(null);
    if (failed) return setNotice({ userId, text: failed });
    setRejecting(null);
    setNotice(
      decision === "approve"
        ? { userId, text: `Approved "${item.title}". It's public now.`, undo: item }
        : decision === "reject"
          ? { userId, text: `"${item.title}" wasn't approved. Its owner can see why.`, undo: item }
          : { userId, text: `"${item.title}" is back in the queue.` },
    );
    void dropChanged(item.id);
    reload();
    setVersion((v) => v + 1);
  }

  function showOnMap(item: QueueItem) {
    focus(item);
    setSheet("peek");
  }

  return (
    <>
      <div className="flex flex-col gap-1">
        <h1 className="text-[22px] font-bold">Review</h1>
        <p className="text-sm text-muted">
          A person checks each new account&apos;s first drop. Approve anything that follows the content rules; if
          something doesn&apos;t, say why. The owner sees the reason.
        </p>
      </div>

      {session.status === "loading" && <p className="text-sm text-muted">Loading…</p>}
      {session.status === "signed-out" && <SignIn next="/review" lead="Sign in with a staff account." />}

      {userId && !current && <p className="text-sm text-muted">Loading the queue…</p>}
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
              onClick={() => notice.undo && act(notice.undo, "reopen")}
              className={textButton}
            >
              Undo
            </button>
          )}
        </p>
      )}

      {current?.queue && (
        <section className="flex flex-col gap-2" aria-labelledby="queue-heading">
          <h2 id="queue-heading" className="text-base font-semibold">
            {current.queue.length === 0
              ? "Nothing waiting"
              : `${current.queue.length} waiting`}
          </h2>
          {current.queue.length === 0 && (
            <p className="text-sm text-muted">New accounts&apos; first drops show up here.</p>
          )}
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

                {rejecting === item.id ? (
                  <form
                    className="flex flex-col gap-2 rounded-lg border border-line p-3"
                    onSubmit={(event) => {
                      event.preventDefault();
                      const reason = reasonFor();
                      if (!reason) return setNotice({ userId, text: "Say why it isn't approved. The owner sees the reason." });
                      void act(item, "reject", reason.slice(0, REASON_MAX));
                    }}
                  >
                    <fieldset className="flex flex-col gap-2">
                      <legend className="mb-1 text-sm font-semibold">Why isn&apos;t it approved?</legend>
                      {[...REJECT_REASONS, OTHER].map((reason) => (
                        <label key={reason} className={`${choiceCard} p-2.5`}>
                          <input
                            type="radio"
                            name={`reason-${item.id}`}
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
                    <div className="flex gap-2">
                      <button
                        type="submit"
                        disabled={busy === item.id}
                        className="min-h-11 flex-1 rounded-lg bg-rejected px-3 text-sm font-semibold text-white disabled:opacity-60"
                      >
                        Don&apos;t approve
                      </button>
                      <button
                        type="button"
                        onClick={() => setRejecting(null)}
                        className="min-h-11 flex-1 rounded-lg border border-line px-3 text-sm font-semibold hover:bg-wash"
                      >
                        Cancel
                      </button>
                    </div>
                  </form>
                ) : (
                  <div className="flex flex-wrap items-center gap-2">
                    <button
                      type="button"
                      disabled={busy === item.id}
                      onClick={() => act(item, "approve")}
                      className="min-h-11 rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-strong disabled:opacity-60"
                    >
                      Approve
                    </button>
                    <button
                      type="button"
                      disabled={busy === item.id}
                      onClick={() => openReject(item.id)}
                      className="min-h-11 rounded-lg border border-line px-4 text-sm font-semibold hover:bg-wash disabled:opacity-60"
                    >
                      Don&apos;t approve
                    </button>
                    <button type="button" onClick={() => showOnMap(item)} className={textButton}>
                      Show on the map
                    </button>
                  </div>
                )}
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
              const canReopen = latest && event.action !== "reopen" && (event.review === "approved" || event.review === "rejected");
              return (
                <li key={event.id} className="flex flex-col text-sm">
                  <span>
                    <b className="font-semibold">{ACTION_WORDS[event.action]}</b>: {event.title}
                    {event.review === null && <span className="text-muted"> (since deleted)</span>}
                  </span>
                  {event.reason && <span className="text-[13px] text-muted">{event.reason}</span>}
                  <span className="flex flex-wrap items-center gap-x-2 text-[13px] text-muted">
                    {event.by}, {timeAgo(event.at)}
                    {canReopen && (
                      <button
                        type="button"
                        disabled={busy === event.dropId}
                        onClick={() => act({ id: event.dropId, title: event.title }, "reopen")}
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
