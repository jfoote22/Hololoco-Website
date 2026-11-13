"use client";

// Search for a place (Mapbox) or a drop (by title or who posted it), as a combobox:
// type, then pick with the arrow keys and Enter, or tap a result.

import { useRouter } from "next/navigation";
import { useEffect, useId, useRef, useState } from "react";
import { DropThumb } from "@/components/DropThumb";
import { useMap } from "@/components/map/MapProvider";
import { byline } from "@/lib/drops/format";
import { searchDrops } from "@/lib/drops/source";
import type { PublicDrop } from "@/lib/drops/types";
import { searchPlaces, zoomForPlace, type Place } from "@/lib/map/places";

const token = process.env.NEXT_PUBLIC_MAPBOX_TOKEN;

type Result = { kind: "drop"; drop: PublicDrop } | { kind: "place"; place: Place };
type Found = { query: string; results: Result[]; failed: boolean };

const MIN_CHARS = 2;

export function SearchBox({
  placesOnly = false,
  onPlace,
}: {
  /** Only places, for the add flow: drops aren't somewhere you put things. */
  placesOnly?: boolean;
  /** Called after the map moves to a chosen place. */
  onPlace?: (place: Place) => void;
} = {}) {
  const router = useRouter();
  const { engine, setSheet } = useMap();
  const listId = useId();
  const input = useRef<HTMLInputElement>(null);
  const [query, setQuery] = useState("");
  const [found, setFound] = useState<Found | null>(null);
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(-1);

  const trimmed = query.trim();
  const ready = trimmed.length >= MIN_CHARS && found?.query === trimmed;
  const results = ready ? found.results : [];
  const showList = open && results.length > 0;

  useEffect(() => {
    if (trimmed.length < MIN_CHARS) return;
    const controller = new AbortController();
    const timer = setTimeout(async () => {
      const near = engine?.getCenter();
      const [drops, places] = await Promise.all([
        placesOnly ? Promise.resolve([]) : searchDrops(trimmed),
        token && near
          ? searchPlaces(trimmed, near, token, controller.signal).catch((error: unknown) => {
              if (controller.signal.aborted) throw error;
              return null;
            })
          : Promise.resolve([]),
      ]).catch(() => [null, null] as const);
      if (controller.signal.aborted || drops === null) return;
      setFound({
        query: trimmed,
        failed: places === null,
        results: [
          ...drops.map((drop) => ({ kind: "drop" as const, drop })),
          ...(places ?? []).map((place) => ({ kind: "place" as const, place })),
        ],
      });
      setActive(-1);
    }, 250);
    return () => {
      clearTimeout(timer);
      controller.abort();
    };
  }, [trimmed, engine, placesOnly]);

  function choose(result: Result | undefined) {
    if (!result) return;
    setOpen(false);
    setActive(-1);
    if (result.kind === "drop") {
      setQuery("");
      router.push(`/d/${result.drop.id}`);
      return;
    }
    const { place } = result;
    setQuery(place.name);
    input.current?.blur();
    setSheet("peek");
    const precise = ["address", "secondary_address", "street"].includes(place.kind);
    if (place.bounds && !precise) engine?.fitBounds(place.bounds, { maxZoom: zoomForPlace(place.kind) });
    else engine?.flyTo({ center: place.center, zoom: zoomForPlace(place.kind) });
    onPlace?.(place);
  }

  function onKeyDown(event: React.KeyboardEvent<HTMLInputElement>) {
    if (event.key === "ArrowDown" && results.length) {
      event.preventDefault();
      setOpen(true);
      setActive((i) => (i + 1) % results.length);
    } else if (event.key === "ArrowUp" && results.length) {
      event.preventDefault();
      setOpen(true);
      setActive((i) => (i <= 0 ? results.length - 1 : i - 1));
    } else if (event.key === "Escape") {
      if (open && results.length) setOpen(false);
      else setQuery("");
    }
  }

  const status = !ready
    ? ""
    : results.length === 0
      ? found.failed
        ? "Place search isn't working right now."
        : "No matches."
      : `${results.length} results.`;

  return (
    <form
      role="search"
      className="relative z-20"
      onSubmit={(event) => {
        event.preventDefault();
        choose(results[active >= 0 ? active : 0]);
      }}
    >
      <label className="flex min-h-12 items-center gap-2.5 rounded-[10px] border border-line bg-surface px-3.5 focus-within:border-accent max-md:border-transparent max-md:shadow-[0_4px_16px_rgb(23_36_44/0.16)]">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="var(--color-muted)" strokeWidth="1.8" strokeLinecap="round" aria-hidden="true" className="shrink-0">
          <circle cx="11" cy="11" r="7" />
          <path d="M20 20l-3.5-3.5" />
        </svg>
        <span className="sr-only">{placesOnly ? "Search a place" : "Search a place or a drop"}</span>
        <input
          ref={input}
          type="search"
          role="combobox"
          aria-expanded={showList}
          aria-controls={listId}
          aria-autocomplete="list"
          aria-activedescendant={showList && active >= 0 ? `${listId}-${active}` : undefined}
          autoComplete="off"
          enterKeyHint="search"
          placeholder="Search a place"
          value={query}
          onChange={(event) => {
            setQuery(event.target.value);
            setOpen(true);
          }}
          onFocus={() => setOpen(true)}
          onBlur={() => setOpen(false)}
          onKeyDown={onKeyDown}
          className="min-w-0 flex-1 bg-transparent text-[15px] outline-none placeholder:text-muted"
        />
      </label>

      <ul
        id={listId}
        role="listbox"
        aria-label="Search results"
        hidden={!showList}
        className="absolute inset-x-0 top-full mt-1 max-h-[min(60dvh,360px)] overflow-y-auto rounded-[10px] border border-line bg-surface py-1 shadow-(--shadow-panel)"
      >
        {results.map((result, i) => (
          <li
            key={result.kind === "drop" ? `d-${result.drop.id}` : `p-${result.place.id}`}
            id={`${listId}-${i}`}
            role="option"
            aria-selected={i === active}
            onPointerDown={(event) => event.preventDefault()}
            onClick={() => choose(result)}
            className="flex min-h-12 cursor-pointer items-center gap-3 px-3 py-1.5 aria-selected:bg-wash hover:bg-wash"
          >
            {result.kind === "drop" ? (
              <>
                <DropThumb drop={result.drop} className="size-9" imageClassName="size-7" />
                <span className="flex min-w-0 flex-col">
                  <span className="truncate text-[15px] font-semibold">{result.drop.title}</span>
                  <span className="truncate text-[13px] text-muted">{byline(result.drop)}</span>
                </span>
              </>
            ) : (
              <>
                <span className="flex size-9 shrink-0 items-center justify-center" aria-hidden="true">
                  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="var(--color-muted)" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
                    <path d="M12 21s7-6.2 7-11.5A7 7 0 005 9.5C5 14.8 12 21 12 21z" />
                    <circle cx="12" cy="9.5" r="2.5" />
                  </svg>
                </span>
                <span className="flex min-w-0 flex-col">
                  <span className="truncate text-[15px]">{result.place.name}</span>
                  {result.place.detail && <span className="truncate text-[13px] text-muted">{result.place.detail}</span>}
                </span>
              </>
            )}
          </li>
        ))}
      </ul>
      <p role="status" className="sr-only">
        {open ? status : ""}
      </p>
      {open && ready && results.length === 0 && (
        <p className="absolute inset-x-0 top-full mt-1 rounded-[10px] border border-line bg-surface px-3 py-2.5 text-sm text-muted shadow-(--shadow-panel)">
          {status}
        </p>
      )}
    </form>
  );
}
