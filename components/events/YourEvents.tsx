"use client";

// Events (the Events plan): link some of your own drops into a hunt (find them all,
// in any order) or a trail (in order) for a set time. Players get XP at each stop,
// and a bonus, points and optionally one of your offers when they finish.

import Link from "next/link";
import { useEffect, useState } from "react";
import { SignIn } from "@/components/auth/SignIn";
import { useSession } from "@/components/auth/session";
import { useMyPlan } from "@/components/plan/useMyPlan";
import { choiceCard, inputClass, labelClass, primaryButton, secondaryButton, textButton } from "@/components/ui";
import { listMyDrops } from "@/lib/drops/mine";
import type { MyDrop } from "@/lib/drops/types";
import { deleteEvent, eventLimits, listMyEvents, saveEvent, type BusinessEvent, type EventInput } from "@/lib/events";
import { allowed } from "@/lib/plans";

type Form = EventInput & { start: string; end: string };

const pad = (n: number) => String(n).padStart(2, "0");
/** A Date as a datetime-local value in this browser's clock. */
const local = (date: Date) =>
  `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;

function blankForm(): Form {
  const start = new Date();
  start.setMinutes(0, 0, 0);
  start.setHours(start.getHours() + 1);
  const end = new Date(start.getTime() + 7 * 24 * 3600 * 1000);
  return {
    title: "",
    description: "",
    format: "hunt",
    startsAt: "",
    endsAt: "",
    start: local(start),
    end: local(end),
    stopXp: 25,
    bonusXp: 300,
    bonusPoints: 50,
    rewardDropId: null,
    paused: false,
    stops: [],
  };
}

function formFrom(event: BusinessEvent): Form {
  return {
    id: event.id,
    title: event.title,
    description: event.description,
    format: event.format,
    startsAt: event.startsAt,
    endsAt: event.endsAt,
    start: local(new Date(event.startsAt)),
    end: local(new Date(event.endsAt)),
    stopXp: event.stopXp,
    bonusXp: event.bonusXp,
    bonusPoints: event.bonusPoints,
    rewardDropId: event.reward?.dropId ?? null,
    paused: event.paused,
    stops: event.stops.map((s) => s.dropId),
  };
}

function whenText(event: BusinessEvent): string {
  const now = Date.now();
  const options: Intl.DateTimeFormatOptions = { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" };
  const span = `${new Date(event.startsAt).toLocaleString(undefined, options)} to ${new Date(event.endsAt).toLocaleString(undefined, options)}`;
  if (event.paused) return `Paused · ${span}`;
  if (new Date(event.endsAt).getTime() <= now) return `Ended · ${span}`;
  if (new Date(event.startsAt).getTime() > now) return `Coming up · ${span}`;
  return `On now · ${span}`;
}

export function YourEvents() {
  const session = useSession();
  const userId = session.status === "signed-in" ? session.user.id : null;
  const plan = useMyPlan();
  const [version, setVersion] = useState(0);
  const [loaded, setLoaded] = useState<{ userId: string; events: BusinessEvent[]; drops: MyDrop[]; error: string | null } | null>(null);
  const [form, setForm] = useState<Form | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [confirming, setConfirming] = useState<string | null>(null);

  const can = plan ? allowed(plan).events : false;

  useEffect(() => {
    if (!userId || !can) return;
    let cancelled = false;
    Promise.all([listMyEvents(), listMyDrops()])
      .then(([events, drops]) => !cancelled && setLoaded({ userId, events, drops, error: null }))
      .catch((e: Error) => !cancelled && setLoaded({ userId, events: [], drops: [], error: e.message }));
    return () => {
      cancelled = true;
    };
  }, [userId, can, version]);

  const mine = loaded?.userId === userId ? loaded : null;
  const usable = mine?.drops.filter((d) => d.review !== "rejected") ?? [];
  const offers = usable.filter((d) => d.type === "offer");
  const titleOf = (id: string) => mine?.drops.find((d) => d.id === id)?.title ?? "A deleted drop";

  function change(update: Partial<Form>) {
    setForm((f) => (f ? { ...f, ...update } : f));
  }

  function toggleStop(id: string) {
    if (!form) return;
    change({ stops: form.stops.includes(id) ? form.stops.filter((s) => s !== id) : [...form.stops, id] });
  }

  function move(id: string, by: -1 | 1) {
    if (!form) return;
    const stops = [...form.stops];
    const at = stops.indexOf(id);
    const to = at + by;
    if (at < 0 || to < 0 || to >= stops.length) return;
    [stops[at], stops[to]] = [stops[to], stops[at]];
    change({ stops });
  }

  async function save() {
    if (!form) return;
    const startsAt = new Date(form.start);
    const endsAt = new Date(form.end);
    if (!form.title.trim()) return setError("Give the event a title.");
    if (Number.isNaN(startsAt.getTime()) || Number.isNaN(endsAt.getTime()) || endsAt <= startsAt)
      return setError("The event has to end after it starts.");
    if (form.stops.length < eventLimits.minStops) return setError(`Choose at least ${eventLimits.minStops} stops.`);
    setBusy(true);
    setError(null);
    const { start: _start, end: _end, ...rest } = form;
    void _start;
    void _end;
    const saved = await saveEvent({
      ...rest,
      title: form.title.trim(),
      description: form.description.trim(),
      startsAt: startsAt.toISOString(),
      endsAt: endsAt.toISOString(),
    });
    setBusy(false);
    if ("error" in saved) return setError(saved.error);
    setForm(null);
    setVersion((v) => v + 1);
  }

  async function remove(id: string) {
    setBusy(true);
    const failed = await deleteEvent(id);
    setBusy(false);
    setConfirming(null);
    if (failed) return setError(failed);
    setVersion((v) => v + 1);
  }

  async function togglePause(event: BusinessEvent) {
    setBusy(true);
    const saved = await saveEvent({ ...formFrom(event), paused: !event.paused });
    setBusy(false);
    if ("error" in saved) return setError(saved.error);
    setVersion((v) => v + 1);
  }

  const number = (value: string) => (value === "" ? 0 : Math.max(0, Math.floor(Number(value))));

  return (
    <>
      <div className="flex flex-col gap-1">
        <h1 className="text-[22px] font-bold">Events</h1>
        <p className="text-sm text-muted">
          Turn your drops into a game for a set time. Players get XP at each stop, and a bonus, points and a reward when
          they finish.
        </p>
      </div>

      {session.status === "loading" && <p className="text-sm text-muted">Loading…</p>}
      {session.status === "signed-out" && <SignIn next="/events" lead="Sign in to make events." />}
      {userId && plan === undefined && <p className="text-sm text-muted">Loading…</p>}
      {userId && plan !== undefined && !can && (
        <div className="flex flex-col gap-1 rounded-lg bg-wash px-3 py-2.5 text-sm">
          <b className="font-semibold">Events come with the Events plan</b>
          <span>Hunts and trails across your locations, with bonus XP, points and rewards for players who finish.</span>
          <Link href="/plan" className={`${textButton} self-start`}>
            See plans
          </Link>
        </div>
      )}

      {can && !mine && <p className="text-sm text-muted">Loading your events…</p>}
      {mine?.error && <p className="text-sm text-rejected">{mine.error}</p>}

      {can && mine && !form && (
        <button type="button" onClick={() => setForm(blankForm())} className={primaryButton}>
          New event
        </button>
      )}

      {form && (
        <form
          className="flex flex-col gap-4 rounded-lg border border-line p-3"
          onSubmit={(event) => {
            event.preventDefault();
            void save();
          }}
        >
          <h2 className="text-base font-semibold">{form.id ? "Edit the event" : "New event"}</h2>
          <label className={labelClass}>
            Title
            <input value={form.title} maxLength={70} onChange={(e) => change({ title: e.target.value })} className={inputClass} />
          </label>
          <label className={labelClass}>
            What players do (optional)
            <textarea
              value={form.description}
              maxLength={400}
              rows={2}
              onChange={(e) => change({ description: e.target.value })}
              className={`${inputClass} py-2 leading-normal`}
            />
          </label>

          <fieldset className="flex flex-col gap-2">
            <legend className="mb-2 text-sm font-semibold">Kind of event</legend>
            <label className={choiceCard}>
              <input type="radio" name="format" checked={form.format === "hunt"} onChange={() => change({ format: "hunt" })} className="mt-1 accent-accent" />
              <span className="text-sm">
                <b className="block">Hunt</b>
                <span className="text-muted">Find every stop, in any order.</span>
              </span>
            </label>
            <label className={choiceCard}>
              <input type="radio" name="format" checked={form.format === "trail"} onChange={() => change({ format: "trail" })} className="mt-1 accent-accent" />
              <span className="text-sm">
                <b className="block">Trail</b>
                <span className="text-muted">Visit the stops in order.</span>
              </span>
            </label>
          </fieldset>

          <div className="grid grid-cols-2 gap-3">
            <label className={labelClass}>
              Starts
              <input type="datetime-local" value={form.start} onChange={(e) => change({ start: e.target.value })} className={inputClass} />
            </label>
            <label className={labelClass}>
              Ends
              <input type="datetime-local" value={form.end} onChange={(e) => change({ end: e.target.value })} className={inputClass} />
            </label>
          </div>

          <fieldset className="flex flex-col gap-2">
            <legend className="mb-1 text-sm font-semibold">
              Stops ({form.stops.length} of {eventLimits.minStops} to {eventLimits.maxStops})
            </legend>
            {usable.length < eventLimits.minStops && (
              <p className="text-sm text-muted">Add at least {eventLimits.minStops} drops to the map first; they become the stops.</p>
            )}
            {form.stops.length > 0 && (
              <ol className="flex flex-col gap-1">
                {form.stops.map((id, i) => (
                  <li key={id} className="flex items-center gap-2 rounded-lg bg-wash px-3 py-1 text-sm">
                    <span className="w-5 font-semibold">{i + 1}</span>
                    <span className="min-w-0 flex-1 truncate">{titleOf(id)}</span>
                    {form.format === "trail" && (
                      <>
                        <button type="button" onClick={() => move(id, -1)} disabled={i === 0} aria-label={`Move ${titleOf(id)} earlier`} className={`${textButton} min-h-9`}>
                          ↑
                        </button>
                        <button type="button" onClick={() => move(id, 1)} disabled={i === form.stops.length - 1} aria-label={`Move ${titleOf(id)} later`} className={`${textButton} min-h-9`}>
                          ↓
                        </button>
                      </>
                    )}
                  </li>
                ))}
              </ol>
            )}
            <ul className="flex max-h-64 flex-col gap-1 overflow-y-auto">
              {usable.map((drop) => (
                <li key={drop.id}>
                  <label className="flex min-h-11 cursor-pointer items-center gap-3 text-sm">
                    <input
                      type="checkbox"
                      checked={form.stops.includes(drop.id)}
                      disabled={!form.stops.includes(drop.id) && form.stops.length >= eventLimits.maxStops}
                      onChange={() => toggleStop(drop.id)}
                      className="accent-accent"
                    />
                    <span className="min-w-0 truncate">{drop.title}</span>
                  </label>
                </li>
              ))}
            </ul>
          </fieldset>

          <div className="grid grid-cols-3 gap-3">
            <label className={labelClass}>
              XP a stop
              <input type="number" inputMode="numeric" min={0} max={eventLimits.maxStopXp} value={form.stopXp}
                onChange={(e) => change({ stopXp: Math.min(number(e.target.value), eventLimits.maxStopXp) })} className={inputClass} />
            </label>
            <label className={labelClass}>
              Bonus XP
              <input type="number" inputMode="numeric" min={0} max={eventLimits.maxBonusXp} value={form.bonusXp}
                onChange={(e) => change({ bonusXp: Math.min(number(e.target.value), eventLimits.maxBonusXp) })} className={inputClass} />
            </label>
            <label className={labelClass}>
              Points
              <input type="number" inputMode="numeric" min={0} max={eventLimits.maxBonusPoints} value={form.bonusPoints}
                onChange={(e) => change({ bonusPoints: Math.min(number(e.target.value), eventLimits.maxBonusPoints) })} className={inputClass} />
            </label>
          </div>

          <label className={labelClass}>
            Reward for finishing (optional)
            <select
              value={form.rewardDropId ?? ""}
              onChange={(e) => change({ rewardDropId: e.target.value || null })}
              className={inputClass}
            >
              <option value="">No reward, just the bonus</option>
              {offers.map((offer) => (
                <option key={offer.id} value={offer.id}>
                  {offer.offer?.savings ?? offer.title}
                </option>
              ))}
            </select>
            <span className="text-xs font-normal text-muted">
              One of your offers, given to each player who finishes while it lasts. It counts against the offer&apos;s stock.
            </span>
          </label>

          {error && (
            <p role="alert" className="text-sm text-rejected">
              {error}
            </p>
          )}
          <div className="flex gap-2">
            <button type="button" onClick={() => setForm(null)} className={`${secondaryButton} flex-1`}>
              Cancel
            </button>
            <button type="submit" disabled={busy} className={`${primaryButton} flex-[2]`}>
              {busy ? "Saving…" : form.id ? "Save changes" : "Create the event"}
            </button>
          </div>
        </form>
      )}

      {!form && error && (
        <p role="alert" className="text-sm text-rejected">
          {error}
        </p>
      )}

      {mine && mine.events.length === 0 && !form && <p className="text-sm text-muted">No events yet.</p>}
      {mine && mine.events.length > 0 && (
        <ul className="flex flex-col divide-y divide-line">
          {mine.events.map((event) => (
            <li key={event.id} className="flex flex-col gap-1 py-3">
              <span className="font-semibold break-words">{event.title}</span>
              <span className="text-[13px] text-muted">
                {event.format === "hunt" ? "Hunt" : "Trail"} · {event.stops.length} stops · {whenText(event)}
              </span>
              <span className="text-[13px] text-muted">
                {event.started} started · {event.finished} finished
                {event.reward ? ` · Reward: ${event.reward.savings} (${event.reward.remaining} left)` : ""}
              </span>
              {confirming === event.id ? (
                <div className="flex flex-wrap items-center gap-x-3 rounded-lg bg-wash px-3 py-1">
                  <span className="text-sm">Delete this event? Players lose their progress.</span>
                  <button type="button" disabled={busy} onClick={() => remove(event.id)} className={`${textButton} text-rejected`}>
                    Delete
                  </button>
                  <button type="button" onClick={() => setConfirming(null)} className={textButton}>
                    Keep it
                  </button>
                </div>
              ) : (
                <div className="flex flex-wrap gap-x-3">
                  <button type="button" onClick={() => { setForm(formFrom(event)); setError(null); }} className={textButton}>
                    Edit
                  </button>
                  <button type="button" disabled={busy} onClick={() => togglePause(event)} className={textButton}>
                    {event.paused ? "Resume" : "Pause"}
                  </button>
                  <button type="button" onClick={() => setConfirming(event.id)} className={`${textButton} text-muted`}>
                    Delete
                  </button>
                </div>
              )}
            </li>
          ))}
        </ul>
      )}
    </>
  );
}
