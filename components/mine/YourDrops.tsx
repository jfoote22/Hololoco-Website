"use client";

// Your drops: everything the person has added, with its status in words, and
// edit, pause and delete. Signing in starts here too.

import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { useEffect, useState } from "react";
import { dropChanged } from "@/app/actions";
import { SignIn } from "@/components/auth/SignIn";
import { signOut, useSession } from "@/components/auth/session";
import { DropThumb } from "@/components/DropThumb";
import { useMap } from "@/components/map/MapProvider";
import { primaryButton, textButton } from "@/components/ui";
import { timingText, typeLabel } from "@/lib/drops/format";
import { deleteDrop, getProfile, listMyDrops, setPaused } from "@/lib/drops/mine";
import type { MyDrop } from "@/lib/drops/types";

type Loaded = { userId: string; drops: MyDrop[] | null; error: string | null; isStaff: boolean };

function statusOf(drop: MyDrop): { word: string; tone: string; line?: string } {
  if (drop.review === "rejected")
    return {
      word: "Not approved",
      tone: "text-rejected",
      line: `${drop.reviewReason ?? "It doesn't follow the content rules."} Edit it to send it back for review.`,
    };
  if (drop.review === "pending" && drop.hiddenForReport)
    return { word: "Hidden for now", tone: "text-review", line: "Someone reported it. It's off the map until a person checks it." };
  if (drop.review === "pending")
    return { word: "In review", tone: "text-review", line: "Only you can see it until a person has checked it." };
  if (drop.paused) return { word: "Paused", tone: "text-muted", line: "Hidden until you resume it." };
  if (drop.audience === "link") return { word: "Live, link only", tone: "text-good" };
  if (!drop.openNow) return { word: "Live, outside its hours", tone: "text-good", line: timingText(drop.timing) ?? undefined };
  return { word: "Live", tone: "text-good" };
}

export function YourDrops() {
  const session = useSession();
  const params = useSearchParams();
  const { focus, setSheet, reload } = useMap();
  const userId = session.status === "signed-in" ? session.user.id : null;
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  const [confirming, setConfirming] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  useEffect(() => {
    if (!userId) return;
    let cancelled = false;
    Promise.all([listMyDrops(), getProfile(userId)])
      .then(([drops, profile]) => !cancelled && setLoaded({ userId, drops, error: null, isStaff: profile?.isStaff ?? false }))
      .catch((error: Error) => !cancelled && setLoaded({ userId, drops: null, error: error.message, isStaff: false }));
    return () => {
      cancelled = true;
    };
  }, [userId]);

  const mine = loaded?.userId === userId ? loaded : null;
  const added = params.get("added");
  const saved = params.get("saved");

  function replace(id: string, change: (drop: MyDrop) => MyDrop | null) {
    setLoaded((l) =>
      l?.drops ? { ...l, drops: l.drops.flatMap((d) => (d.id === id ? [change(d)].filter((x) => x !== null) : [d])) } : l,
    );
  }

  async function togglePause(drop: MyDrop) {
    setBusy(drop.id);
    setActionError(null);
    const failed = await setPaused(drop.id, !drop.paused);
    setBusy(null);
    if (failed) return setActionError(failed);
    replace(drop.id, (d) => ({ ...d, paused: !d.paused, status: d.paused ? "live" : "paused" }));
    void dropChanged(drop.id);
    reload();
  }

  async function remove(drop: MyDrop) {
    setBusy(drop.id);
    setActionError(null);
    const failed = await deleteDrop(drop.id);
    setBusy(null);
    setConfirming(null);
    if (failed) return setActionError(failed);
    replace(drop.id, () => null);
    void dropChanged(drop.id);
    reload();
  }

  function showOnMap(drop: MyDrop) {
    focus(drop);
    setSheet("peek");
  }

  return (
    <>
      <div className="flex flex-col gap-1">
        <h1 className="text-[22px] font-bold">Your drops</h1>
        <p className="text-sm text-muted">Everything you&apos;ve added, and whether it&apos;s on the map.</p>
      </div>

      {params.get("signin") === "failed" && (
        <p role="alert" className="rounded-lg bg-wash px-3 py-2.5 text-sm">
          That sign-in link didn&apos;t work. It may have expired or been used already, so ask for a new one.
        </p>
      )}

      {session.status === "loading" && <p className="text-sm text-muted">Loading…</p>}

      {session.status === "signed-out" && <SignIn next="/mine" lead="Sign in to see and change what you've added." />}

      {userId && (
        <>
          {added && mine?.drops?.some((d) => d.id === added && d.review === "pending") && (
            <p role="status" className="rounded-lg bg-accent-wash px-3 py-2.5 text-sm">
              Thanks! Your drop is in review. A person checks each new account&apos;s first drop, usually within a day.
              Until then only you can see it.
            </p>
          )}
          {mine?.isStaff && (
            <Link href="/review" className={`${textButton} self-start`}>
              Open the review queue
            </Link>
          )}
          {saved && (
            <p role="status" className="rounded-lg bg-accent-wash px-3 py-2.5 text-sm">
              Changes saved.
            </p>
          )}
          {actionError && (
            <p role="alert" className="text-sm text-rejected">
              {actionError}
            </p>
          )}

          {!mine && <p className="text-sm text-muted">Loading your drops…</p>}
          {mine?.error && <p className="text-sm text-rejected">{mine.error}</p>}
          {mine?.drops?.length === 0 && (
            <div className="flex flex-col gap-3">
              <p className="text-sm text-muted">You haven&apos;t added anything yet.</p>
              <Link href="/add" className={primaryButton}>
                Add to the map
              </Link>
            </div>
          )}

          {mine?.drops && mine.drops.length > 0 && (
            <ul className="flex flex-col divide-y divide-line">
              {mine.drops.map((drop) => {
                const status = statusOf(drop);
                const isPublic = drop.review === "approved" && !drop.paused;
                return (
                  <li key={drop.id} className="flex flex-col gap-2 py-3">
                    <div className="flex items-start gap-3">
                      <DropThumb drop={drop} />
                      <div className="flex min-w-0 flex-col">
                        <span className="truncate font-semibold">{drop.title}</span>
                        <span className="text-[13px] text-muted">
                          {typeLabel[drop.type]} · <b className={`font-semibold ${status.tone}`}>{status.word}</b>
                        </span>
                        {status.line && <span className="text-[13px] text-muted">{status.line}</span>}
                      </div>
                    </div>

                    {confirming === drop.id ? (
                      <div className="flex flex-wrap items-center gap-x-3 rounded-lg bg-wash px-3 py-1">
                        <span className="text-sm">Delete this drop? This can&apos;t be undone.</span>
                        <button
                          type="button"
                          disabled={busy === drop.id}
                          onClick={() => remove(drop)}
                          className={`${textButton} text-rejected`}
                        >
                          Delete
                        </button>
                        <button type="button" onClick={() => setConfirming(null)} className={textButton}>
                          Keep it
                        </button>
                      </div>
                    ) : (
                      <div className="flex flex-wrap gap-x-3">
                        {isPublic ? (
                          <Link href={`/d/${drop.id}`} className={textButton}>
                            Open
                          </Link>
                        ) : (
                          <button type="button" onClick={() => showOnMap(drop)} className={textButton}>
                            Show on the map
                          </button>
                        )}
                        <Link href={`/add?edit=${drop.id}`} className={textButton}>
                          Edit
                        </Link>
                        {drop.review !== "rejected" && (
                          <button
                            type="button"
                            disabled={busy === drop.id}
                            onClick={() => togglePause(drop)}
                            className={textButton}
                          >
                            {drop.paused ? "Resume" : "Pause"}
                          </button>
                        )}
                        <button type="button" onClick={() => setConfirming(drop.id)} className={`${textButton} text-muted`}>
                          Delete
                        </button>
                      </div>
                    )}
                  </li>
                );
              })}
            </ul>
          )}

          <div className="mt-auto flex flex-wrap items-center justify-between gap-2 border-t border-line pt-3 text-sm text-muted">
            <span className="min-w-0 truncate">Signed in as {session.status === "signed-in" ? session.user.email : ""}</span>
            <button type="button" onClick={() => void signOut()} className={textButton}>
              Sign out
            </button>
          </div>
        </>
      )}
    </>
  );
}
