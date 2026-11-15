"use client";

// The start page. Signed out, it says what the website is for and offers sign-in.
// Signed in, it's Your drops: everything the person has added, with its status in
// words, and add, edit, pause and delete.

import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { useEffect, useState } from "react";
import { signOut, useSession } from "@/components/auth/session";
import { DropThumb } from "@/components/DropThumb";
import { useMap } from "@/components/map/MapProvider";
import { SheetHeight } from "@/components/map/SheetHeight";
import { useQuestRoute } from "@/components/map/useQuestRoute";
import { QuestStages } from "@/components/QuestStages";
import { SearchBox } from "@/components/SearchBox";
import { primaryButton, textButton } from "@/components/ui";
import { Welcome } from "./Welcome";
import { offerCountText, rarityLabel, rarityText, timingText, typeLabel } from "@/lib/drops/format";
import { attachPreviews } from "@/lib/assets";
import { deleteDrop, getProfile, getStanding, listMyDrops, setPaused, setRarity, type Standing } from "@/lib/drops/mine";
import type { MyDrop, Rarity } from "@/lib/drops/types";
import { allowed, planNames } from "@/lib/plans";
import { getQuest, type Quest } from "@/lib/quests";
import { useMyPlan } from "@/components/plan/useMyPlan";

type Loaded = {
  userId: string;
  drops: MyDrop[] | null;
  error: string | null;
  isStaff: boolean;
  standing: Standing | null;
};

/** The automatic check hasn't finished with it yet. */
const isChecking = (drop: MyDrop) =>
  drop.review === "pending" &&
  ((drop.check !== null && ["queued", "running", "retry"].includes(drop.check.state)) || isPhotoChecking(drop));

/** Its photo is still in the automatic photo check. */
const isPhotoChecking = (drop: MyDrop) => drop.photoCheck === "queued" || drop.photoCheck === "running";

function statusOf(drop: MyDrop, suspended: boolean): { word: string; tone: string; line?: string } {
  if (suspended && drop.review === "approved")
    return { word: "Hidden", tone: "text-muted", line: "Hidden from the app while your account is suspended." };
  if (drop.review === "rejected")
    return {
      word: "Not approved",
      tone: "text-rejected",
      line: `${drop.reviewReason ?? "It doesn't follow the content rules."} Edit it to send it back for review.`,
    };
  if (drop.review === "pending" && drop.hiddenForReport)
    return { word: "Hidden for now", tone: "text-review", line: "Someone reported it. It's off the map until a person checks it." };
  if (isPhotoChecking(drop) && drop.review === "pending")
    return { word: "Checking", tone: "text-review", line: "An automatic check is looking at your photo. This usually takes a few seconds." };
  if (isChecking(drop))
    return { word: "Checking", tone: "text-review", line: "An automatic check is looking at it. This usually takes under a minute." };
  if (drop.review === "pending") {
    const person =
      drop.look.kind === "upload" && drop.look.status !== "approved"
        ? drop.look.assetKind === "photo"
          ? "A person is checking your photo, usually within a day."
          : "A person checks every 3D model, usually within a day."
        : "A person is checking it, usually within a day.";
    return {
      word: "In review",
      tone: "text-review",
      line: `${drop.check?.ownerNote ? `${drop.check.ownerNote} ` : ""}${person} Until then only you can see it.`,
    };
  }
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
  // The quest opened from one of the person's offers, drawn on the map.
  const [openQuest, setOpenQuest] = useState<{ dropId: string; quest: Quest } | null>(null);
  const showRoute = useQuestRoute();
  const plan = useMyPlan();

  useEffect(() => {
    if (!userId) return;
    let cancelled = false;
    Promise.all([listMyDrops().then(attachPreviews), getProfile(userId), getStanding()])
      .then(
        ([drops, profile, standing]) =>
          !cancelled && setLoaded({ userId, drops, error: null, isStaff: profile?.isStaff ?? false, standing }),
      )
      .catch(
        (error: Error) =>
          !cancelled && setLoaded({ userId, drops: null, error: error.message, isStaff: false, standing: null }),
      );
    return () => {
      cancelled = true;
    };
  }, [userId]);

  const mine = loaded?.userId === userId ? loaded : null;
  const checking = mine?.drops?.filter(isChecking).map((d) => d.id).join(",") ?? "";

  // While the automatic check works on something, look again every few seconds,
  // for up to about three minutes.
  useEffect(() => {
    if (!userId || !checking) return;
    let cancelled = false;
    let tries = 0;
    let timer: ReturnType<typeof setTimeout>;
    const look = () => {
      timer = setTimeout(async () => {
        tries++;
        try {
          const drops = await attachPreviews(await listMyDrops());
          if (cancelled) return;
          setLoaded((l) => (l?.userId === userId ? { ...l, drops } : l));
          const still = drops.filter(isChecking).map((d) => d.id).join(",");
          if (still !== checking) reload();
          if (still && tries < 45) look();
        } catch {
          if (!cancelled && tries < 45) look();
        }
      }, 4000);
    };
    look();
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [userId, checking, reload]);
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
    reload();
  }

  async function changeRarity(drop: MyDrop, rarity: Rarity) {
    if (!drop.offer) return;
    setBusy(drop.id);
    setActionError(null);
    const failed = await setRarity(drop.id, rarity);
    setBusy(null);
    if (failed) return setActionError(failed);
    // Changing it sends the offer back for the check.
    replace(drop.id, (d) =>
      d.offer ? { ...d, offer: { ...d.offer, rarity }, review: "pending", check: { state: "queued" } } : d,
    );
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
    reload();
  }

  async function toggleQuest(drop: MyDrop) {
    if (!drop.quest) return;
    if (openQuest?.dropId === drop.id) {
      setOpenQuest(null);
      return showRoute(null);
    }
    setBusy(drop.id);
    const quest = await getQuest(drop.quest.id);
    setBusy(null);
    if (!quest) return setActionError("That quest couldn't be loaded. Try again in a moment.");
    setOpenQuest({ dropId: drop.id, quest });
    showRoute(quest);
  }

  function showOnMap(drop: MyDrop) {
    focus(drop);
    setSheet("peek");
  }

  const signInFailed = params.get("signin") === "failed" && (
    <p role="alert" className="rounded-lg bg-wash px-3 py-2.5 text-sm">
      That sign-in link didn&apos;t work. It may have expired or been used already, so ask for a new one.
    </p>
  );

  if (session.status === "loading") return <p className="text-sm text-muted">Loading…</p>;
  if (session.status !== "signed-in") {
    return (
      <>
        {signInFailed}
        <Welcome />
      </>
    );
  }

  const justAdded = added ? mine?.drops?.find((d) => d.id === added) : undefined;
  const suspended = mine?.standing?.standing === "suspended";

  return (
    <>
      <SheetHeight size="half" />
      <div className="flex flex-col gap-1">
        <h1 className="text-[22px] font-bold">Your drops</h1>
        <p className="text-sm text-muted">Everything you&apos;ve added. Once it&apos;s live, people can find it in the Hololoco app.</p>
      </div>

      {signInFailed}

      {mine?.standing && mine.standing.standing !== "good" && !mine.isStaff && (
        <StandingNotice standing={mine.standing} />
      )}

      {justAdded && (
        <p role="status" className="rounded-lg bg-accent-wash px-3 py-2.5 text-sm">
          {justAdded.review !== "pending"
            ? "Thanks! Your drop is live."
            : isPhotoChecking(justAdded)
              ? "Thanks! An automatic check is looking at your photo now. This usually takes a few seconds."
              : justAdded.look.kind === "upload" && justAdded.look.status !== "approved" && justAdded.look.assetKind === "model"
              ? "Thanks! Your drop is in review. A person checks every 3D model, usually within a day. Until then only you can see it."
              : isChecking(justAdded)
                ? "Thanks! An automatic check is looking at it now. This usually takes under a minute."
                : "Thanks! A person will check it, usually within a day. Until then only you can see it."}
        </p>
      )}
      {mine?.isStaff && (
        <div className="flex flex-wrap gap-x-4">
          <Link href="/review" className={textButton}>
            Open the review queue
          </Link>
          <Link href="/quests" className={textButton}>
            See all quests
          </Link>
        </div>
      )}
      <nav aria-label="Your account" className="flex flex-wrap gap-x-4">
        <Link href="/plan" className={textButton}>
          {plan && !plan.staff ? `Your plan: ${planNames[plan.plan]}` : "Plans"}
        </Link>
        {(mine?.drops?.some((d) => d.type === "offer") || (plan && allowed(plan).offers && !plan.staff)) && (
          <Link href="/redeem" className={textButton}>
            Redeem a code
          </Link>
        )}
        {plan && allowed(plan).events && (
          <Link href="/events" className={textButton}>
            Events
          </Link>
        )}
      </nav>
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

      {!suspended && (
        <>
          <Link href="/add" className={primaryButton}>
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden="true">
              <path d="M12 5v14M5 12h14" />
            </svg>
            Add to the map
          </Link>
          <SearchBox />
        </>
      )}

      {!mine && <p className="text-sm text-muted">Loading your drops…</p>}
      {mine?.error && <p className="text-sm text-rejected">{mine.error}</p>}
      {mine?.drops?.length === 0 && <p className="text-sm text-muted">You haven&apos;t added anything yet.</p>}

      {mine?.drops && mine.drops.length > 0 && (
        <ul className="flex flex-col divide-y divide-line">
          {mine.drops.map((drop) => {
            const status = statusOf(drop, suspended);
            return (
              <li key={drop.id} className="flex flex-col gap-2 py-3">
                <div className="flex items-start gap-3">
                  <DropThumb drop={drop} />
                  <div className="flex min-w-0 flex-col">
                    <span className="truncate font-semibold">{drop.title}</span>
                    <span className="text-[13px] text-muted">
                      {typeLabel[drop.type]} · <b className={`font-semibold ${status.tone}`}>{status.word}</b>
                    </span>
                    {drop.offer && (
                      <span className="text-[13px] text-muted">
                        {drop.offer.savings} · {offerCountText(drop.offer)} · {rarityText(drop.offer)}
                      </span>
                    )}
                    {drop.stats && drop.stats.captures > 0 && (
                      <span className="text-[13px] text-muted">
                        {drop.stats.captures === 1 ? "Collected once" : `Collected ${drop.stats.captures} times`}
                        {drop.offer && drop.stats.redeemed !== null ? ` · ${drop.stats.redeemed} redeemed` : ""}
                      </span>
                    )}
                    {status.line && <span className="text-[13px] text-muted">{status.line}</span>}
                    {drop.quest && drop.review === "approved" && !suspended && (
                      <span className="text-[13px] text-muted">
                        Stage {drop.quest.position} of {drop.quest.stageCount} in a quest
                      </span>
                    )}
                  </div>
                </div>

                {openQuest?.dropId === drop.id && <QuestStages quest={openQuest.quest} highlight={drop.id} />}

                <CheckTips drop={drop} busy={busy === drop.id} onUseRarity={(rarity) => changeRarity(drop, rarity)} />

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
                    <button type="button" onClick={() => showOnMap(drop)} className={textButton}>
                      Show on the map
                    </button>
                    {drop.quest && drop.review === "approved" && !suspended && (
                      <button
                        type="button"
                        disabled={busy === drop.id}
                        aria-expanded={openQuest?.dropId === drop.id}
                        onClick={() => toggleQuest(drop)}
                        className={textButton}
                      >
                        {openQuest?.dropId === drop.id ? "Hide the quest" : "Show the quest"}
                      </button>
                    )}
                    {!suspended && (
                      <Link href={`/add?edit=${drop.id}`} className={textButton}>
                        Edit
                      </Link>
                    )}
                    {drop.review !== "rejected" && !suspended && (
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
        <span className="min-w-0 truncate">Signed in as {session.user.email}</span>
        <button type="button" onClick={() => void signOut()} className={textButton}>
          Sign out
        </button>
      </div>
    </>
  );
}

/** Why this account's drops wait for a person, or why it can't add any. */
function StandingNotice({ standing }: { standing: Standing }) {
  const taken = standing.strikes === 1 ? "one of your drops" : `${standing.strikes} of your drops`;
  if (standing.standing === "suspended")
    return (
      <p role="status" className="rounded-lg bg-wash px-3 py-2.5 text-sm">
        <b className="block font-semibold text-rejected">Your account is suspended</b>
        Hololoco took down three of your drops, so your drops are hidden from the app and you can&apos;t add or change
        any. You can still delete them. If you think this is a mistake, contact Hololoco.
      </p>
    );
  return (
    <p role="status" className="rounded-lg bg-wash px-3 py-2.5 text-sm">
      <b className="block font-semibold text-review">A person checks your drops for now</b>
      {standing.strikes > 0
        ? `Hololoco took down ${taken}, so your new drops and changes wait for a person before people can see them, usually within a day. After three, your account is suspended.`
        : "Someone reported one of your drops. Until a person has looked at it, your new drops and changes wait for a person before people can see them, usually within a day."}
    </p>
  );
}

/** What the automatic check suggests: a different rarity for an offer, and where to put it. */
function CheckTips({ drop, busy, onUseRarity }: { drop: MyDrop; busy: boolean; onUseRarity: (rarity: Rarity) => void }) {
  const check = drop.check;
  if (!check || check.state !== "done" || drop.review === "rejected") return null;
  const suggested = drop.offer && check.suggestedRarity && check.suggestedRarity !== drop.offer.rarity ? check.suggestedRarity : null;
  // A held drop's note is already in its status line.
  const note = drop.review === "approved" ? check.ownerNote : undefined;
  if (!suggested && !check.placementTip && !note) return null;
  return (
    <div className="flex flex-col gap-1.5 rounded-lg bg-wash px-3 py-2 text-[13px]">
      {note && <p>{note}</p>}
      {suggested && (
        <div className="flex flex-wrap items-center gap-x-3">
          <p className="min-w-0 flex-1">
            <b className="font-semibold">Our check suggests {rarityLabel[suggested]}.</b> {check.rarityReason}
          </p>
          <button type="button" disabled={busy} onClick={() => onUseRarity(suggested)} className={`${textButton} min-h-9 text-[13px]`}>
            Make it {rarityLabel[suggested]}
          </button>
        </div>
      )}
      {check.placementTip && (
        <p>
          <b className="font-semibold">Tip:</b> {check.placementTip}
        </p>
      )}
    </div>
  );
}
