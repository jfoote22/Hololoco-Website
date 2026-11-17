"use client";

// Staff go through what the finder found around town as a list. Tick several and
// approve or decline them together, or open one to see everything about it. The map
// beside the list has one pin per place, with a count where several events share it;
// clicking that pin narrows the list to that place. Filters narrow it by type, date,
// distance from the middle of the map, and words.
//
// Keys: ↑ and ↓ move through the list, Space ticks, A approves and X declines (the
// ticked ones, or else the open one).

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { SignIn } from "@/components/auth/SignIn";
import { useSession } from "@/components/auth/session";
import { useMap } from "@/components/map/MapProvider";
import { inputClass, primaryButton, secondaryButton, textButton } from "@/components/ui";
import {
  categoryLabel,
  categoryObject,
  distanceText,
  foundApi,
  isWhen,
  metresBetween,
  placedByText,
  rejectReasons,
  spotKey,
  topicLabel,
  whenOptions,
  whenText,
  type FinderState,
  type FoundApi,
  type FoundCategory,
  type FoundEvent,
  type FoundQueue,
  type FoundStatus,
  type When,
} from "@/lib/found";
import { libraryObject } from "@/lib/library/objects";
import type { LngLat, MapPin } from "@/lib/map/engine";
import { START_VIEW } from "@/lib/map/start";
import { timeAgo } from "@/lib/review";

const TABS: { status: FoundStatus; label: string }[] = [
  { status: "pending", label: "Waiting" },
  { status: "approved", label: "On the map" },
  { status: "rejected", label: "Declined" },
];

const DISTANCES = [
  { metres: 0, label: "Any distance" },
  { metres: 1000, label: "Within 1 km" },
  { metres: 3000, label: "Within 3 km" },
  { metres: 10_000, label: "Within 10 km" },
  { metres: 25_000, label: "Within 25 km" },
];

const SPOT_PIN = "found-spot:";
const DECLINE_KEY_REASON = "Not a fit for the map";

const chipClass =
  "flex min-h-9 items-center gap-1.5 rounded-full border border-line px-3 text-[13px] font-medium hover:bg-wash aria-pressed:border-accent aria-pressed:bg-accent-wash aria-pressed:text-accent";
const smallButton = "flex min-h-10 items-center justify-center gap-2 rounded-xl px-3 text-sm font-semibold disabled:opacity-50";

const thumbFor = (category: FoundCategory) => libraryObject(categoryObject[category])?.thumbnail ?? "";

/** A found event as the pin being moved: its category's object, at its spot. */
function movePin(event: FoundEvent, at: LngLat): MapPin {
  const object = libraryObject(categoryObject[event.category]);
  return {
    id: `found-move-${event.id}`,
    type: "message",
    title: event.title,
    placement: { lat: at.lat, lng: at.lng, height: 3, size: 6, turn: 0 },
    thumbnail: object?.thumbnail,
    modelUrl: object?.model,
  };
}

/** Staff only. Signed out, it asks for a staff account; the database refuses everyone else. */
export function FoundReviewScreen() {
  const session = useSession();
  return (
    <>
      <div className="flex flex-col gap-1">
        <Link href="/review" className={`${textButton} -ml-1 self-start`}>
          ‹ Review
        </Link>
        <h1 className="text-[22px] font-bold">Found events</h1>
        <p className="text-sm text-muted max-md:hidden">
          Games, shows, festivals, business events, giveaways and deals the finder found around Austin. Approve the
          ones worth finding: they go on the map in the app until they end.
        </p>
      </div>
      {session.status === "loading" && <p className="text-sm text-muted">Loading…</p>}
      {session.status === "signed-out" && <SignIn next="/review/found" lead="Sign in with a staff account." />}
      {session.status === "signed-in" && <FoundReview key={session.user.id} />}
    </>
  );
}

export function FoundReview({ api = foundApi }: { api?: FoundApi }) {
  const { engine, setDraft, setOverlay, setSheet } = useMap();
  const [status, setStatus] = useState<FoundStatus>("pending");
  const [queue, setQueue] = useState<FoundQueue | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [version, setVersion] = useState(0);

  const [types, setTypes] = useState<Set<FoundCategory>>(new Set());
  const [when, setWhen] = useState<When>("any");
  const [within, setWithin] = useState(0);
  const [words, setWords] = useState("");
  const [spot, setSpot] = useState<string | null>(null);
  const [sort, setSort] = useState<"soonest" | "nearest">("soonest");
  const [movedTo, setMovedTo] = useState<LngLat | null>(null);

  const [openId, setOpenId] = useState<string | null>(null);
  const [checked, setChecked] = useState<Set<string>>(new Set());
  const [titles, setTitles] = useState<Record<string, string>>({});
  const [moving, setMoving] = useState<{ id: string; at: LngLat } | null>(null);
  const [declining, setDeclining] = useState<"open" | "checked" | null>(null);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<{ text: string; undo?: { ids: string[] } } | null>(null);
  const rows = useRef(new Map<string, HTMLLIElement>());

  useEffect(() => {
    let cancelled = false;
    api
      .load(status)
      .then((loaded) => {
        if (cancelled) return;
        setQueue(loaded);
        setLoadError(null);
      })
      .catch((error: Error) => !cancelled && setLoadError(error.message));
    return () => {
      cancelled = true;
    };
  }, [api, status, version]);

  // Distances are from the middle of the map, so moving the map moves the filter.
  useEffect(() => engine?.onMove(() => setMovedTo(engine.getCenter())), [engine]);
  const live = movedTo ?? engine?.getCenter() ?? START_VIEW.center;
  // Kept by value, so the same spot is the same object and nothing redraws for nothing.
  const centerLat = Math.round(live.lat * 1e5) / 1e5;
  const centerLng = Math.round(live.lng * 1e5) / 1e5;
  const center = useMemo(() => ({ lat: centerLat, lng: centerLng }), [centerLat, centerLng]);

  // On a phone, half the screen for the list and half for the map.
  useEffect(() => setSheet("half"), [setSheet]);

  const all = useMemo(() => (queue?.items ?? []).filter((e) => e.status === status), [queue, status]);
  const distanceOf = useCallback((e: FoundEvent) => metresBetween(center, e.placement), [center]);

  // Every filter but the type, so the type chips can count what each would show.
  const beforeTypes = useMemo(() => {
    const text = words.trim().toLowerCase();
    return all.filter(
      (e) =>
        isWhen(e, when) &&
        (within === 0 || distanceOf(e) <= within) &&
        (!text || `${e.title} ${e.venue} ${e.organizer}`.toLowerCase().includes(text)),
    );
  }, [all, when, within, words, distanceOf]);

  // The map shows every place that passes the filters, so another place can be picked.
  const onMap = useMemo(() => beforeTypes.filter((e) => types.size === 0 || types.has(e.category)), [beforeTypes, types]);

  const listed = useMemo(() => {
    const here = onMap.filter((e) => !spot || spotKey(e) === spot);
    return sort === "nearest"
      ? [...here].sort((a, b) => distanceOf(a) - distanceOf(b))
      : here; // The database sends them soonest first.
  }, [onMap, spot, sort, distanceOf]);

  const typeCounts = useMemo(() => {
    const counts = new Map<FoundCategory, number>();
    for (const e of beforeTypes) counts.set(e.category, (counts.get(e.category) ?? 0) + 1);
    return [...counts.entries()].sort((a, b) => b[1] - a[1]);
  }, [beforeTypes]);

  const spots = useMemo(() => {
    const groups = new Map<string, FoundEvent[]>();
    for (const e of onMap) {
      const key = spotKey(e);
      groups.set(key, [...(groups.get(key) ?? []), e]);
    }
    return groups;
  }, [onMap]);

  const open = listed.find((e) => e.id === openId) ?? null;
  const openIndex = open ? listed.indexOf(open) : -1;
  const ticked = listed.filter((e) => checked.has(e.id));
  const spotName = spot ? (spots.get(spot)?.[0]?.venue || "this spot") : null;

  // One pin per place: the count shows how many events share it.
  useEffect(() => {
    const pins: MapPin[] = [];
    for (const [key, events] of spots) {
      const first = events[0];
      pins.push({
        id: SPOT_PIN + key,
        type: "message",
        title: events.length === 1 ? first.title : `${first.venue || "Here"} · ${events.length} events`,
        placement: { lat: first.placement.lat, lng: first.placement.lng, height: 3, size: 6, turn: 0 },
        thumbnail: thumbFor(first.category),
        count: events.length,
      });
    }
    setOverlay(pins);
  }, [spots, setOverlay]);

  // The open event's pin is the highlighted one.
  const openSpot = open ? spotKey(open) : null;
  useEffect(() => {
    engine?.setSelected(openSpot ? SPOT_PIN + openSpot : null);
  }, [engine, openSpot, spots]);

  // The map flies to each event as it opens.
  const flownTo = useRef<string | null>(null);
  useEffect(() => {
    if (!engine || !open || flownTo.current === open.id) return;
    const first = flownTo.current === null;
    flownTo.current = open.id;
    engine.flyTo({ center: open.placement, zoom: Math.max(engine.getZoom(), 15.8) }, { instant: first });
  }, [engine, open]);

  // Moving a pin: the event's object on a handle to drag.
  useEffect(() => {
    const event = moving ? all.find((e) => e.id === moving.id) : null;
    setDraft(event && moving ? movePin(event, moving.at) : null);
  }, [moving, all, setDraft]);

  useEffect(() => {
    if (!engine) return;
    return engine.onDraftMove((at) => setMoving((m) => (m ? { ...m, at } : m)));
  }, [engine]);

  useEffect(
    () => () => {
      setOverlay(null);
      setDraft(null);
    },
    [setOverlay, setDraft],
  );

  const openRow = useCallback((id: string | null) => {
    setOpenId(id);
    setDeclining(null);
    setMoving(null);
    if (id) rows.current.get(id)?.scrollIntoView({ block: "nearest" });
  }, []);

  // A place's pin narrows the list to that place, and opens the first event there.
  useEffect(() => {
    if (!engine) return;
    return engine.onPinSelect((pinId) => {
      if (!pinId.startsWith(SPOT_PIN)) return;
      const key = pinId.slice(SPOT_PIN.length);
      const events = spots.get(key);
      if (!events?.length) return;
      setSpot(events.length > 1 ? key : null);
      openRow(events[0].id);
    });
  }, [engine, spots, openRow]);

  const move = useCallback(
    (step: number) => {
      if (listed.length === 0) return;
      const next = openIndex === -1 ? 0 : Math.min(listed.length - 1, Math.max(0, openIndex + step));
      openRow(listed[next].id);
    },
    [listed, openIndex, openRow],
  );

  const toggle = useCallback((id: string) => {
    setChecked((c) => {
      const next = new Set(c);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }, []);

  /** Approve, decline or send back: the ticked ones, or the open one. */
  const decide = useCallback(
    async (decision: "approve" | "reject" | "pending", targets: FoundEvent[], reason?: string) => {
      if (targets.length === 0 || busy) return;
      setBusy(true);
      setDeclining(null);
      try {
        const ids = targets.map((e) => e.id);
        let done = 0;
        let failed: string[] = [];
        if (targets.length === 1) {
          const target = targets[0];
          const title = titles[target.id]?.trim();
          await api.review(target.id, decision, { title: title && title !== target.title ? title : undefined, reason });
          done = 1;
        } else {
          const result = await api.reviewMany(ids, decision, reason);
          done = result.done;
          failed = result.failed.map((f) => f.id);
        }
        // What left the list goes at once; the next event opens in its place.
        const leaving = new Set(ids.filter((id) => !failed.includes(id)));
        if (open && leaving.has(open.id)) {
          const after = listed.slice(openIndex + 1).find((e) => !leaving.has(e.id));
          const before = listed.slice(0, openIndex).reverse().find((e) => !leaving.has(e.id));
          openRow((after ?? before)?.id ?? null);
        }
        setQueue((q) => q && { ...q, items: q.items.filter((e) => !leaving.has(e.id)) });
        setChecked((c) => new Set([...c].filter((id) => !leaving.has(id))));
        const what = done === 1 ? `"${targets.find((t) => leaving.has(t.id))?.title ?? targets[0].title}"` : `${done} events`;
        const verb =
          decision === "approve" ? `${done === 1 ? "is" : "are"} on the map until ${done === 1 ? "it ends" : "they end"}` : decision === "reject" ? "won't go on the map" : `${done === 1 ? "is" : "are"} back with the ones waiting`;
        setNotice({
          text: `${what} ${verb}.${failed.length ? ` ${failed.length} couldn't be changed (already over, or gone).` : ""}`,
          undo: decision === "pending" ? undefined : { ids: [...leaving] },
        });
        setVersion((v) => v + 1);
      } catch (error) {
        setNotice({ text: (error as Error).message });
      } finally {
        setBusy(false);
      }
    },
    [api, busy, titles, open, listed, openIndex, openRow],
  );

  const targetsNow = useCallback(() => (ticked.length > 0 ? ticked : open ? [open] : []), [ticked, open]);

  async function saveSpot() {
    if (!moving) return;
    setBusy(true);
    try {
      const updated = await api.review(moving.id, "move", { at: moving.at });
      setMoving(null);
      setNotice({ text: `Saved the new spot${updated.venue ? ` for ${updated.venue}, and every event waiting there` : ""}.` });
      setVersion((v) => v + 1);
    } catch (error) {
      setNotice({ text: (error as Error).message });
    } finally {
      setBusy(false);
    }
  }

  async function undo(ids: string[]) {
    setBusy(true);
    try {
      await api.reviewMany(ids, "pending");
      setNotice({ text: ids.length === 1 ? "Undone. It's back with the ones waiting." : `Undone. ${ids.length} events are back with the ones waiting.` });
      setVersion((v) => v + 1);
    } catch (error) {
      setNotice({ text: (error as Error).message });
    } finally {
      setBusy(false);
    }
  }

  async function runFinder() {
    setBusy(true);
    try {
      await api.runFinder();
      setNotice({ text: "The finder is searching every topic. New events show up here as it finishes, usually within the hour." });
      setVersion((v) => v + 1);
    } catch (error) {
      setNotice({ text: (error as Error).message });
    } finally {
      setBusy(false);
    }
  }

  function nearMe() {
    if (!engine || !("geolocation" in navigator)) return;
    navigator.geolocation.getCurrentPosition(
      (position) => engine.flyTo({ center: { lat: position.coords.latitude, lng: position.coords.longitude }, zoom: 13 }),
      () => setNotice({ text: "Couldn't get your location. Check that this site is allowed to use it." }),
      { timeout: 10_000, maximumAge: 60_000 },
    );
  }

  // Keys, unless someone is typing.
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const typing = event.target instanceof Element && event.target.closest("input, textarea, select, [contenteditable]");
      if (event.metaKey || event.ctrlKey || event.altKey || typing) return;
      if (event.key === "ArrowDown" || event.key === "j") move(1);
      else if (event.key === "ArrowUp" || event.key === "k") move(-1);
      else if (event.key === " " && open) toggle(open.id);
      else if ((event.key === "a" || event.key === "A") && status !== "approved") void decide("approve", targetsNow());
      else if ((event.key === "x" || event.key === "X") && status !== "rejected") void decide("reject", targetsNow(), DECLINE_KEY_REASON);
      else if (event.key === "Escape") {
        if (declining) setDeclining(null);
        else if (spot) setSpot(null);
        else openRow(null);
      } else return;
      event.preventDefault();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [move, toggle, decide, targetsNow, open, status, declining, spot, openRow]);

  if (loadError && !queue) {
    return (
      <p className="rounded-lg bg-wash px-3 py-2.5 text-sm">
        {loadError}{" "}
        <button type="button" className="font-semibold text-accent hover:underline" onClick={() => setVersion((v) => v + 1)}>
          Try again
        </button>
      </p>
    );
  }
  if (!queue) return <p className="text-sm text-muted">Loading…</p>;

  const allTicked = listed.length > 0 && listed.every((e) => checked.has(e.id));
  const someTicked = ticked.length > 0 && !allTicked;
  const filtered = types.size > 0 || when !== "any" || within > 0 || words.trim() !== "" || spot !== null;

  return (
    <>
      <div role="tablist" aria-label="Which events" className="flex gap-1 rounded-xl bg-wash p-1">
        {TABS.map((tab) => (
          <button
            key={tab.status}
            type="button"
            role="tab"
            aria-selected={status === tab.status}
            onClick={() => {
              setStatus(tab.status);
              setChecked(new Set());
              openRow(null);
            }}
            className="flex min-h-10 flex-1 items-center justify-center gap-1.5 rounded-lg px-2 text-sm font-semibold text-muted aria-selected:bg-surface aria-selected:text-ink aria-selected:shadow-sm"
          >
            {tab.label}
            <span className="text-[13px] font-medium text-muted">{queue.counts[tab.status]}</span>
          </button>
        ))}
      </div>

      <section aria-label="Filters" className="flex flex-col gap-2.5">
        <label className="flex">
          <span className="sr-only">Search</span>
          <input
            type="search"
            className={`${inputClass} min-h-10`}
            placeholder="Search titles, places and organizers"
            value={words}
            onChange={(e) => setWords(e.target.value)}
          />
        </label>
        <div className="flex flex-wrap gap-1.5" role="group" aria-label="Type of event">
          <button type="button" className={chipClass} aria-pressed={types.size === 0} onClick={() => setTypes(new Set())}>
            All types
          </button>
          {typeCounts.map(([category, count]) => (
            <button
              key={category}
              type="button"
              className={chipClass}
              aria-pressed={types.has(category)}
              onClick={() =>
                setTypes((t) => {
                  const next = new Set(t);
                  if (next.has(category)) next.delete(category);
                  else next.add(category);
                  return next;
                })
              }
            >
              {categoryLabel[category]}
              <span className="text-muted">{count}</span>
            </button>
          ))}
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <label className="flex items-center">
            <span className="sr-only">When</span>
            <select className={`${inputClass} min-h-10 w-auto`} value={when} onChange={(e) => setWhen(e.target.value as When)}>
              {whenOptions.map((o) => (
                <option key={o.id} value={o.id}>
                  {o.label}
                </option>
              ))}
            </select>
          </label>
          <label className="flex items-center">
            <span className="sr-only">Distance from the middle of the map</span>
            <select className={`${inputClass} min-h-10 w-auto`} value={within} onChange={(e) => setWithin(Number(e.target.value))}>
              {DISTANCES.map((d) => (
                <option key={d.metres} value={d.metres}>
                  {d.label}
                </option>
              ))}
            </select>
          </label>
          <label className="flex items-center">
            <span className="sr-only">Order</span>
            <select className={`${inputClass} min-h-10 w-auto`} value={sort} onChange={(e) => setSort(e.target.value as "soonest" | "nearest")}>
              <option value="soonest">Soonest first</option>
              <option value="nearest">Nearest first</option>
            </select>
          </label>
          <button type="button" className={`${textButton} min-h-10`} onClick={nearMe}>
            Near me
          </button>
        </div>
        <p className="text-[13px] text-muted">
          Distances are from the middle of the map. Move the map, or use Near me.
          {filtered && (
            <>
              {" "}
              <button
                type="button"
                className="font-semibold text-accent hover:underline"
                onClick={() => {
                  setTypes(new Set());
                  setWhen("any");
                  setWithin(0);
                  setWords("");
                  setSpot(null);
                }}
              >
                Clear filters
              </button>
            </>
          )}
        </p>
        {spot && (
          <p className="flex items-center gap-2 self-start rounded-full bg-accent-wash py-1 pr-1 pl-3 text-sm font-medium">
            At {spotName}: {listed.length} event{listed.length === 1 ? "" : "s"}
            <button
              type="button"
              aria-label="Show every place"
              className="flex size-7 items-center justify-center rounded-full hover:bg-surface"
              onClick={() => setSpot(null)}
            >
              ✕
            </button>
          </p>
        )}
      </section>

      {notice && (
        <p role="status" className="flex flex-wrap items-center gap-x-3 rounded-lg bg-accent-wash px-3 py-2 text-sm">
          {notice.text}
          {notice.undo && (
            <button type="button" disabled={busy} className="font-semibold text-accent hover:underline" onClick={() => undo(notice.undo!.ids)}>
              Undo
            </button>
          )}
        </p>
      )}

      {/* What to do with the ticked ones. It stays at the top while the list scrolls. */}
      <div className="sticky -top-2 z-10 -mx-4 flex flex-wrap items-center gap-2 border-y border-line bg-surface px-4 py-2">
        <label className="flex min-h-10 cursor-pointer items-center gap-2 pr-2 text-sm">
          <input
            type="checkbox"
            className="size-[18px] accent-(--color-accent)"
            checked={allTicked}
            ref={(el) => {
              if (el) el.indeterminate = someTicked;
            }}
            onChange={() => setChecked(allTicked ? new Set() : new Set(listed.map((e) => e.id)))}
            disabled={listed.length === 0}
          />
          {ticked.length > 0 ? `${ticked.length} ticked` : `${listed.length} shown`}
        </label>
        {ticked.length > 0 && (
          <div className="flex flex-wrap gap-2">
            {status !== "approved" && (
              <button type="button" disabled={busy} className={`${smallButton} bg-accent text-on-accent hover:bg-accent-strong`} onClick={() => decide("approve", ticked)}>
                Approve {ticked.length}
              </button>
            )}
            {status !== "rejected" && (
              <button type="button" disabled={busy} className={`${smallButton} border border-line hover:bg-wash`} onClick={() => setDeclining(declining === "checked" ? null : "checked")}>
                {status === "approved" ? `Take ${ticked.length} off the map` : `Decline ${ticked.length}`}
              </button>
            )}
            {status !== "pending" && (
              <button type="button" disabled={busy} className={`${smallButton} border border-line hover:bg-wash`} onClick={() => decide("pending", ticked)}>
                Back to waiting
              </button>
            )}
          </div>
        )}
        {declining === "checked" && (
          <Reasons busy={busy} onPick={(reason) => decide("reject", ticked, reason)} onCancel={() => setDeclining(null)} />
        )}
      </div>

      {listed.length === 0 ? (
        <p className="rounded-xl bg-wash px-4 py-6 text-center text-sm text-muted">
          {filtered
            ? "Nothing matches these filters."
            : status === "pending"
              ? "Nothing waiting. The finder looks again every morning."
              : status === "approved"
                ? "Nothing from the finder is on the map right now."
                : "Nothing declined."}
        </p>
      ) : (
        <ul className="-mx-2 flex flex-col">
          {listed.map((event) => {
            const isOpen = event.id === openId;
            return (
              <li
                key={event.id}
                ref={(el) => {
                  if (el) rows.current.set(event.id, el);
                  else rows.current.delete(event.id);
                }}
                className={`scroll-mt-16 rounded-xl ${isOpen ? "bg-accent-wash" : ""}`}
              >
                <div className="flex items-center gap-2 px-2">
                  <input
                    type="checkbox"
                    className="size-[18px] shrink-0 accent-(--color-accent)"
                    aria-label={`Tick ${event.title}`}
                    checked={checked.has(event.id)}
                    onChange={() => toggle(event.id)}
                  />
                  <button
                    type="button"
                    aria-expanded={isOpen}
                    onClick={() => openRow(isOpen ? null : event.id)}
                    className={`flex min-h-14 min-w-0 flex-1 items-center gap-3 rounded-lg py-1.5 text-left ${isOpen ? "" : "hover:bg-wash"}`}
                  >
                    {/* eslint-disable-next-line @next/next/no-img-element */}
                    <img src={thumbFor(event.category)} alt="" className="size-9 shrink-0 object-contain" />
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-[15px] font-semibold">{titles[event.id] ?? event.title}</span>
                      <span className="block truncate text-[13px] text-muted">
                        {categoryLabel[event.category]}
                        {event.venue && ` · ${event.venue}`} · {distanceText(distanceOf(event))}
                        {event.confidence === "low" && " · check details"}
                      </span>
                    </span>
                    <span className="shrink-0 text-right text-[13px] text-muted max-sm:hidden">{whenText(event)}</span>
                  </button>
                </div>
                {isOpen && (
                  <Details
                    event={event}
                    status={status}
                    busy={busy}
                    title={titles[event.id] ?? event.title}
                    onTitle={(value) => setTitles((t) => ({ ...t, [event.id]: value }))}
                    declining={declining === "open"}
                    onDecline={() => setDeclining(declining === "open" ? null : "open")}
                    onReason={(reason) => decide("reject", [event], reason)}
                    onApprove={() => decide("approve", [event])}
                    onBack={() => decide("pending", [event])}
                    moving={moving?.id === event.id}
                    onMove={() => setMoving({ id: event.id, at: event.placement })}
                    onSaveSpot={saveSpot}
                    onCancelMove={() => setMoving(null)}
                  />
                )}
              </li>
            );
          })}
        </ul>
      )}

      <p className="hidden text-[13px] text-muted md:block">
        Keys: ↑ ↓ move · Space ticks · A approves · X declines (the ticked ones, or the open one) · Esc closes
      </p>

      <Finder finder={queue.finder} busy={busy} onRun={runFinder} />
    </>
  );
}

function Reasons({ busy, onPick, onCancel }: { busy: boolean; onPick: (reason: string) => void; onCancel: () => void }) {
  return (
    <div className="flex w-full flex-wrap items-center gap-2" role="group" aria-label="Why it's not for the map">
      <span className="text-sm font-semibold">Why?</span>
      {rejectReasons.map((reason) => (
        <button key={reason} type="button" disabled={busy} className={`${smallButton} border border-line hover:bg-wash`} onClick={() => onPick(reason)}>
          {reason}
        </button>
      ))}
      <button type="button" className={`${textButton} min-h-10`} onClick={onCancel}>
        Cancel
      </button>
    </div>
  );
}

type DetailsProps = {
  event: FoundEvent;
  status: FoundStatus;
  busy: boolean;
  title: string;
  onTitle: (value: string) => void;
  declining: boolean;
  onDecline: () => void;
  onReason: (reason: string) => void;
  onApprove: () => void;
  onBack: () => void;
  moving: boolean;
  onMove: () => void;
  onSaveSpot: () => void;
  onCancelMove: () => void;
};

/** Everything about the open event, under its row. */
function Details(props: DetailsProps) {
  const { event, status, busy } = props;
  const others = event.sources.filter((s) => s !== event.url);
  return (
    <div className="flex flex-col gap-3 px-3 pt-1 pb-4 sm:pl-[52px]">
      <label className="flex flex-col gap-1 text-[13px] text-muted">
        Title (you can edit it)
        <input
          className={`${inputClass} min-h-10 text-base font-semibold text-ink`}
          value={props.title}
          maxLength={70}
          onChange={(e) => props.onTitle(e.target.value)}
        />
      </label>

      <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1.5 text-sm">
        <dt className="text-muted">When</dt>
        <dd>
          {whenText(event)}
          {event.timeNote && <span className="block text-muted">{event.timeNote}</span>}
        </dd>
        <dt className="text-muted">Where</dt>
        <dd>
          {event.venue || "—"}
          {event.address && <span className="block text-muted">{event.address}</span>}
        </dd>
        {event.price && (
          <>
            <dt className="text-muted">Price</dt>
            <dd>{event.free ? `${event.price} (free)` : event.price}</dd>
          </>
        )}
        {event.organizer && (
          <>
            <dt className="text-muted">By</dt>
            <dd>{event.organizer}</dd>
          </>
        )}
      </dl>

      {event.summary && <p className="text-[15px] leading-relaxed">{event.summary}</p>}
      {event.note && (
        <p className="rounded-lg bg-surface px-3 py-2 text-sm">
          <b className="font-semibold">Note:</b> {event.note}
        </p>
      )}
      {event.confidence !== "high" && (
        <p className="rounded-lg bg-rare-wash px-3 py-2 text-sm text-rare-ink">
          {event.confidence === "low" ? "The finder wasn't sure of everything here. Check the event page." : "Found on a listing site, not the official page."}
        </p>
      )}

      <div className="flex flex-wrap gap-x-4 text-sm">
        {event.url && (
          <a href={event.url} target="_blank" rel="noreferrer" className={textButton}>
            Event page ↗
          </a>
        )}
        {event.ticketUrl && event.ticketUrl !== event.url && (
          <a href={event.ticketUrl} target="_blank" rel="noreferrer" className={textButton}>
            Tickets ↗
          </a>
        )}
        {others.length > 0 && (
          <details className="w-full text-muted">
            <summary className="cursor-pointer py-1">Also on {others.length} more page{others.length === 1 ? "" : "s"}</summary>
            <ul className="flex flex-col gap-1 py-1">
              {others.map((s) => (
                <li key={s} className="truncate">
                  <a href={s} target="_blank" rel="noreferrer" className="text-accent hover:underline">
                    {s.replace(/^https?:\/\/(www\.)?/, "")}
                  </a>
                </li>
              ))}
            </ul>
          </details>
        )}
      </div>

      {props.moving ? (
        <div className="flex flex-col gap-2 rounded-lg bg-rare-wash p-3 text-sm text-rare-ink">
          Drag the pin on the map to the right spot. Saving moves every event waiting at this venue too.
          <div className="flex gap-2">
            <button type="button" disabled={busy} className={`${smallButton} bg-accent text-on-accent`} onClick={props.onSaveSpot}>
              Save the spot
            </button>
            <button type="button" className={`${smallButton} border border-line bg-surface text-ink`} onClick={props.onCancelMove}>
              Cancel
            </button>
          </div>
        </div>
      ) : (
        <p className="text-[13px] text-muted">
          {placedByText[event.placedBy]}{" "}
          <button type="button" className="font-semibold text-accent hover:underline" onClick={props.onMove}>
            Move the pin
          </button>
        </p>
      )}

      {props.declining ? (
        <Reasons busy={busy} onPick={props.onReason} onCancel={props.onDecline} />
      ) : (
        <div className="flex flex-wrap gap-2">
          {status !== "approved" && (
            <button type="button" disabled={busy} className={`${primaryButton} min-h-11 flex-1`} onClick={props.onApprove}>
              {status === "rejected" ? "Put it on the map after all" : "Approve"}
            </button>
          )}
          {status !== "rejected" && (
            <button type="button" disabled={busy} className={`${secondaryButton} min-h-11 flex-1`} onClick={props.onDecline}>
              {status === "approved" ? "Take it off the map" : "Not for the map"}
            </button>
          )}
          {status !== "pending" && (
            <button type="button" disabled={busy} className={`${secondaryButton} min-h-11 flex-1`} onClick={props.onBack}>
              Back to waiting
            </button>
          )}
        </div>
      )}

      <p className="text-[13px] text-muted">
        {event.topic ? `Found by the finder (${topicLabel[event.topic] ?? event.topic})` : "Added by hand"}, {timeAgo(event.foundAt)}
        {event.reviewedAt && status !== "pending" && `. Reviewed ${timeAgo(event.reviewedAt)}`}
        {event.rejectReason && `: ${event.rejectReason}`}
      </p>
    </div>
  );
}

/** How the finder is doing: when it last searched, what it found and cost, and a button to search now. */
function Finder({ finder, busy, onRun }: { finder: FinderState; busy: boolean; onRun: () => void }) {
  const run = finder.lastRun;
  const searches = run?.searches ?? [];
  const notConfigured = searches.some((s) => s.error === "not_configured");
  const failed = searches.filter((s) => s.status === "failed" && s.error !== "not_configured");
  const added = searches.reduce((sum, s) => sum + s.added, 0);
  const working = searches.filter((s) => s.status !== "done" && s.status !== "failed").length;

  return (
    <section aria-label="The finder" className="flex flex-col gap-2 rounded-xl border border-line px-3 py-2.5 text-sm">
      {notConfigured ? (
        <p className="text-rare-ink">
          The finder can&apos;t search yet: it needs an Anthropic API key. In Supabase, open Edge Functions, then Secrets,
          and add <code>ANTHROPIC_API_KEY</code>, plus <code>MAPBOX_TOKEN</code> (the website&apos;s public Mapbox token) to
          place events by street address.
        </p>
      ) : finder.running ? (
        <p>
          Searching now{run ? `, started ${timeAgo(run.createdAt)}` : ""}.
          {working > 0 && ` ${working} of ${searches.length} topics still going.`} New events show up here as they come in.
        </p>
      ) : run ? (
        <p>
          Last searched {timeAgo(run.finishedAt ?? run.createdAt)}: {added} new
          {searches.length > 0 && ` from ${searches.length} topic${searches.length === 1 ? "" : "s"}`}. It searches again every morning.
        </p>
      ) : (
        <p>The finder searches every morning.</p>
      )}
      {failed.length > 0 && !finder.running && (
        <details className="text-muted">
          <summary className="cursor-pointer">{failed.length} topic{failed.length === 1 ? "" : "s"} didn&apos;t finish</summary>
          <ul className="flex flex-col gap-0.5 py-1">
            {failed.map((s) => (
              <li key={s.topic}>
                {topicLabel[s.topic] ?? s.topic}: {s.error}
              </li>
            ))}
          </ul>
        </details>
      )}
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="text-[13px] text-muted">About ${(finder.costCents30Days / 100).toFixed(2)} in the last 30 days</span>
        <button type="button" className={`${textButton} min-h-9`} disabled={busy || finder.running} onClick={onRun}>
          {finder.running ? "Searching…" : "Search now"}
        </button>
      </div>
    </section>
  );
}
