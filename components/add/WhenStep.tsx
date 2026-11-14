"use client";

// When: Always is the default, so most people just publish. Weekly hours show
// all seven days in every block, and each block must end after it starts.
// Offers also say how rare they are and whether they can be part of quests.

import { useMemo, useState } from "react";
import { choiceCard, inputClass, labelClass, textButton } from "@/components/ui";
import type { Rarity, Timing, Weekday, WeeklyBlock } from "@/lib/drops/types";
import { defaultTiming, type Draft } from "./draft";

const RARITIES: { rarity: Rarity; name: string; line: string }[] = [
  {
    rarity: "common",
    name: "Common",
    line: "An everyday deal, like a dollar off a coffee. People come across it often.",
  },
  {
    rarity: "uncommon",
    name: "Uncommon",
    line: "A better deal, like a free drink with a meal. It shows up less often and looks more special.",
  },
  {
    rarity: "rare",
    name: "Rare",
    line: "Something worth hunting for, like a free meal or merchandise. Hard to find, and saved for the end of a quest.",
  },
];

const DAYS: { day: Weekday; short: string; name: string }[] = [
  { day: 1, short: "M", name: "Monday" },
  { day: 2, short: "T", name: "Tuesday" },
  { day: 3, short: "W", name: "Wednesday" },
  { day: 4, short: "T", name: "Thursday" },
  { day: 5, short: "F", name: "Friday" },
  { day: 6, short: "S", name: "Saturday" },
  { day: 0, short: "S", name: "Sunday" },
];

const MAX_BLOCKS = 7;

type Props = { draft: Draft; update: (change: Partial<Draft>) => void };

export function WhenStep({ draft, update }: Props) {
  const timing = draft.timing;
  const setTiming = (next: Timing) => update({ timing: next });

  return (
    <div className="flex flex-col gap-5">
      <fieldset className="flex flex-col gap-2">
        <legend className="mb-2 text-sm font-semibold">When is it on the map?</legend>
        {(
          [
            ["always", "Always", "Until you pause or delete it."],
            ["once", "One time", "From a start to an end, like an event."],
            ["weekly", "Every week", "On certain days and hours."],
          ] as const
        ).map(([kind, name, line]) => (
          <label key={kind} className={choiceCard}>
            <input
              type="radio"
              name="timing"
              checked={timing.kind === kind}
              onChange={() => setTiming(defaultTiming(kind))}
              className="mt-1 accent-accent"
            />
            <span className="text-sm">
              <b className="block">{name}</b>
              <span className="text-muted">{line}</span>
            </span>
          </label>
        ))}
      </fieldset>

      {timing.kind === "once" && (
        <div className="grid grid-cols-1 gap-3 min-[420px]:grid-cols-2">
          <label className={labelClass}>
            Starts
            <input
              type="datetime-local"
              value={timing.start}
              onChange={(event) => setTiming({ ...timing, start: event.target.value })}
              className={inputClass}
            />
          </label>
          <label className={labelClass}>
            Ends
            <input
              type="datetime-local"
              value={timing.end}
              min={timing.start}
              onChange={(event) => setTiming({ ...timing, end: event.target.value })}
              className={inputClass}
            />
          </label>
        </div>
      )}

      {timing.kind === "weekly" && (
        <div className="flex flex-col gap-3">
          {timing.blocks.map((block, i) => (
            <HoursBlock
              key={i}
              index={i}
              block={block}
              canRemove={timing.blocks.length > 1}
              onChange={(next) => setTiming({ ...timing, blocks: timing.blocks.map((b, j) => (j === i ? next : b)) })}
              onRemove={() => setTiming({ ...timing, blocks: timing.blocks.filter((_, j) => j !== i) })}
            />
          ))}
          {timing.blocks.length < MAX_BLOCKS && (
            <button
              type="button"
              onClick={() =>
                setTiming({ ...timing, blocks: [...timing.blocks, { days: [6, 0], start: "10:00", end: "16:00" }] })
              }
              className={`${textButton} self-start`}
            >
              Add more hours
            </button>
          )}
        </div>
      )}

      {timing.kind !== "always" && <TimeZone value={draft.timeZone} onChange={(timeZone) => update({ timeZone })} />}

      {draft.type === "offer" && (
        <>
          <fieldset className="flex flex-col gap-2">
            <legend className="mb-1 text-sm font-semibold">How rare is it?</legend>
            <p className="mb-1 text-[13px] text-muted">
              Rarer offers are harder to find in the app and look more special.
            </p>
            {RARITIES.map(({ rarity, name, line }) => (
              <label key={rarity} className={choiceCard}>
                <input
                  type="radio"
                  name="rarity"
                  checked={draft.offer.rarity === rarity}
                  onChange={() => update({ offer: { ...draft.offer, rarity } })}
                  className="mt-1 accent-accent"
                />
                <span className="text-sm">
                  <b className="block">{name}</b>
                  <span className="text-muted">{line}</span>
                </span>
              </label>
            ))}
          </fieldset>

          <label className={choiceCard}>
            <input
              type="checkbox"
              checked={draft.offer.inQuests}
              onChange={(event) => update({ offer: { ...draft.offer, inQuests: event.target.checked } })}
              className="mt-1 size-4 accent-accent"
            />
            <span className="text-sm">
              <b className="block">Let it be part of quests</b>
              <span className="text-muted">
                Hololoco can link your offer with other businesses nearby into a quest, where people collect one stage
                after another. Common offers fit the first stages; rare ones the last. You can leave at any time.
              </span>
            </span>
          </label>
        </>
      )}
    </div>
  );
}

function HoursBlock({
  index,
  block,
  canRemove,
  onChange,
  onRemove,
}: {
  index: number;
  block: WeeklyBlock;
  canRemove: boolean;
  onChange: (block: WeeklyBlock) => void;
  onRemove: () => void;
}) {
  const toggle = (day: Weekday) =>
    onChange({ ...block, days: block.days.includes(day) ? block.days.filter((d) => d !== day) : [...block.days, day] });

  return (
    <fieldset className="flex flex-col gap-3 rounded-lg border border-line p-3">
      <legend className="sr-only">Hours, set {index + 1}</legend>
      <div className="flex justify-between gap-1" role="group" aria-label="Days">
        {DAYS.map(({ day, short, name }) => (
          <button
            key={day}
            type="button"
            aria-pressed={block.days.includes(day)}
            aria-label={name}
            title={name}
            onClick={() => toggle(day)}
            className="size-11 rounded-full border border-line text-sm font-semibold aria-pressed:border-accent aria-pressed:bg-accent aria-pressed:text-white"
          >
            {short}
          </button>
        ))}
      </div>
      <div className="grid grid-cols-2 gap-3">
        <label className={labelClass}>
          From
          <input
            type="time"
            value={block.start}
            onChange={(event) => onChange({ ...block, start: event.target.value })}
            className={inputClass}
          />
        </label>
        <label className={labelClass}>
          To
          <input
            type="time"
            value={block.end}
            max="23:59"
            onChange={(event) => onChange({ ...block, end: event.target.value })}
            className={inputClass}
          />
        </label>
      </div>
      {canRemove && (
        <button type="button" onClick={onRemove} className={`${textButton} self-start text-muted`}>
          Remove these hours
        </button>
      )}
    </fieldset>
  );
}

function TimeZone({ value, onChange }: { value: string; onChange: (zone: string) => void }) {
  const [changing, setChanging] = useState(false);
  const zones = useMemo(() => {
    try {
      const all = Intl.supportedValuesOf("timeZone");
      return all.includes(value) ? all : [value, ...all];
    } catch {
      return [value];
    }
  }, [value]);

  if (!changing) {
    return (
      <p className="flex flex-wrap items-center gap-x-2 text-sm text-muted">
        Times are in the {value.replace(/_/g, " ")} time zone.
        <button type="button" onClick={() => setChanging(true)} className={textButton}>
          Change
        </button>
      </p>
    );
  }
  return (
    <label className={labelClass}>
      Time zone where the drop is
      <select value={value} onChange={(event) => onChange(event.target.value)} className={inputClass}>
        {zones.map((zone) => (
          <option key={zone} value={zone}>
            {zone.replace(/_/g, " ")}
          </option>
        ))}
      </select>
    </label>
  );
}
