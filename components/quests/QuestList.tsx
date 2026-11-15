"use client";

// Staff: every quest the database has built, newest first, and those retired in
// the last week with why. Quests rebuild every 15 minutes by themselves; "Build
// quests now" runs it at once. Every call is checked by the database.

import { useEffect, useState } from "react";
import { SignIn } from "@/components/auth/SignIn";
import { useSession } from "@/components/auth/session";
import { useQuestRoute } from "@/components/map/useQuestRoute";
import { QuestStages } from "@/components/QuestStages";
import { textButton } from "@/components/ui";
import { listQuests, rebuildQuests, type Quest } from "@/lib/quests";
import { timeAgo } from "@/lib/review";

type Loaded = { userId: string; quests: Quest[] | null; error: string | null };

export function QuestList() {
  const session = useSession();
  const userId = session.status === "signed-in" ? session.user.id : null;
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  const [version, setVersion] = useState(0);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [shown, setShown] = useState<string | null>(null);
  const showRoute = useQuestRoute();

  useEffect(() => {
    if (!userId) return;
    let cancelled = false;
    listQuests()
      .then((quests) => !cancelled && setLoaded({ userId, quests, error: null }))
      .catch((error: Error) => !cancelled && setLoaded({ userId, quests: null, error: error.message }));
    return () => {
      cancelled = true;
    };
  }, [userId, version]);

  const current = loaded?.userId === userId ? loaded : null;
  const active = current?.quests?.filter((q) => q.status === "active") ?? [];
  const retired = current?.quests?.filter((q) => q.status === "retired") ?? [];

  async function buildNow() {
    setBusy(true);
    setNotice(null);
    const result = await rebuildQuests();
    setBusy(false);
    if ("error" in result) return setNotice(result.error);
    const built = result.built === 1 ? "1 new quest" : `${result.built} new quests`;
    const gone = result.retired === 1 ? "1 retired" : `${result.retired} retired`;
    setNotice(`Done: ${built}, ${gone}.`);
    setVersion((v) => v + 1);
  }

  function show(quest: Quest) {
    if (shown === quest.id) {
      setShown(null);
      return showRoute(null);
    }
    setShown(quest.id);
    showRoute(quest);
  }

  return (
    <>
      <div className="flex flex-col gap-1">
        <h1 className="text-[22px] font-bold">Quests</h1>
        <p className="text-sm text-muted">
          Built every 15 minutes from offers that opted in: a common offer first, one or two uncommon ones, and a rare
          one last, each from a different business, open at the same hours, a short walk apart (farther where
          businesses are spread out). Quests of one kind of business get a theme, like a coffee crawl. A quest retires
          when one of its stages drops out.
        </p>
      </div>

      {session.status === "loading" && <p className="text-sm text-muted">Loading…</p>}
      {session.status === "signed-out" && <SignIn next="/quests" lead="Sign in with a staff account." />}
      {userId && !current && <p className="text-sm text-muted">Loading…</p>}
      {current?.error && (
        <p className="rounded-lg bg-wash px-3 py-2.5 text-sm">
          {current.error.includes("staff") ? "This page is for Hololoco staff." : current.error}
        </p>
      )}

      {current?.quests && (
        <>
          <div className="flex flex-wrap items-center gap-x-3">
            <button
              type="button"
              disabled={busy}
              onClick={buildNow}
              className="min-h-11 rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-strong disabled:opacity-60"
            >
              {busy ? "Building…" : "Build quests now"}
            </button>
            {notice && (
              <span role="status" className="text-sm">
                {notice}
              </span>
            )}
          </div>

          <section className="flex flex-col gap-2" aria-labelledby="active-heading">
            <h2 id="active-heading" className="text-base font-semibold">
              {active.length === 0 ? "No quests yet" : `Active (${active.length})`}
            </h2>
            {active.length === 0 && (
              <p className="text-sm text-muted">
                A quest needs at least a common, an uncommon and a rare offer from three businesses near each other,
                all opted in to quests.
              </p>
            )}
            <ul className="flex flex-col divide-y divide-line">
              {active.map((quest) => (
                <li key={quest.id} className="flex flex-col gap-2 py-3">
                  <div className="flex flex-col">
                    <span className="font-semibold break-words">{quest.name}</span>
                    <span className="text-[13px] text-muted">
                      {quest.stageCount} stages · {quest.openNow ? "open now" : "closed now"} · built{" "}
                      {timeAgo(quest.builtAt)}
                    </span>
                  </div>
                  <QuestStages quest={quest} />
                  <button type="button" onClick={() => show(quest)} className={`${textButton} self-start`}>
                    {shown === quest.id ? "Hide the route" : "Show the route on the map"}
                  </button>
                </li>
              ))}
            </ul>
          </section>

          {retired.length > 0 && (
            <section className="flex flex-col gap-2 border-t border-line pt-3" aria-labelledby="retired-heading">
              <h2 id="retired-heading" className="text-base font-semibold">
                Retired this week
              </h2>
              <ul className="flex flex-col gap-2">
                {retired.map((quest) => (
                  <li key={quest.id} className="flex flex-col text-sm">
                    <span className="break-words">{quest.name}</span>
                    <span className="text-[13px] text-muted">
                      {quest.retiredReason ?? "Retired"} {quest.retiredAt ? timeAgo(quest.retiredAt) : ""}
                    </span>
                  </li>
                ))}
              </ul>
            </section>
          )}
        </>
      )}
    </>
  );
}
