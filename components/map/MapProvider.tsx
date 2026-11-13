"use client";

// Shared state between the map and the panel: which drops are in view, the type
// filter, the drop being looked at, and how tall the phone sheet is. The map stays
// mounted across every route, so this lives in the root layout.

import { useRouter } from "next/navigation";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import { modelFor, thumbnailFor } from "@/lib/drops/format";
import { listDropsInBounds, listPublicDrops } from "@/lib/drops/source";
import type { DropType, PublicDrop } from "@/lib/drops/types";
import type { Insets, MapEngine, MapPin } from "@/lib/map/engine";

export type TypeFilterValue = "all" | DropType;
export type MapStatus = "loading" | "ready" | "unavailable";
export type SheetSize = "peek" | "half" | "full";

/** Zoom used when opening one drop. */
export const DROP_ZOOM = 17.4;

/** Phone sheet heights. Keep in step with the classes in components/Panel.tsx. */
export function sheetPixels(size: SheetSize, viewportHeight: number): number {
  const peek = 188;
  const full = Math.max(peek, viewportHeight - 128);
  if (size === "peek") return peek;
  if (size === "full") return full;
  return Math.min(full, Math.max(peek, Math.round(viewportHeight * 0.55)));
}

function subscribeToResize(onChange: () => void) {
  window.addEventListener("resize", onChange);
  return () => window.removeEventListener("resize", onChange);
}

const viewportSnapshot = () => `${window.innerWidth}x${window.innerHeight}`;

/** Space the panel covers: a 380 px panel on the left on desktop (Tailwind's md), the sheet on phones. */
function insetsFor(viewport: string, sheet: SheetSize): Insets {
  const [width, height] = viewport.split("x").map(Number);
  if (width >= 768) return { top: 0, right: 0, bottom: 0, left: 412 };
  return { top: 112, right: 0, bottom: sheetPixels(sheet, height), left: 0 };
}

type MapContextValue = {
  engine: MapEngine | null;
  status: MapStatus;
  /** Public drops in the visible area, before the type filter. */
  drops: PublicDrop[];
  /** Drops in view that pass the type filter. */
  shownDrops: PublicDrop[];
  filter: TypeFilterValue;
  setFilter: (filter: TypeFilterValue) => void;
  /** The drop whose page is open, if any. */
  focused: PublicDrop | null;
  focus: (drop: PublicDrop | null) => void;
  sheet: SheetSize;
  setSheet: (size: SheetSize) => void;
  insets: Insets | null;
};

type MapInternals = {
  setEngine: (engine: MapEngine | null, status: MapStatus) => void;
  /** The drop to open the map on, when a drop page loads before the map. */
  focusedRef: React.RefObject<PublicDrop | null>;
};

const MapContext = createContext<MapContextValue | null>(null);
const InternalsContext = createContext<MapInternals | null>(null);

export function useMap(): MapContextValue {
  const value = useContext(MapContext);
  if (!value) throw new Error("useMap needs a MapProvider");
  return value;
}

export function useMapInternals(): MapInternals {
  const value = useContext(InternalsContext);
  if (!value) throw new Error("useMapInternals needs a MapProvider");
  return value;
}

function toPin(drop: PublicDrop): MapPin {
  return {
    id: drop.id,
    type: drop.type,
    title: drop.title,
    placement: drop.placement,
    thumbnail: thumbnailFor(drop) ?? undefined,
    modelUrl: modelFor(drop) ?? undefined,
  };
}

export function MapProvider({ children }: { children: React.ReactNode }) {
  const router = useRouter();
  const [engine, setEngineState] = useState<MapEngine | null>(null);
  const [status, setStatus] = useState<MapStatus>("loading");
  const [drops, setDrops] = useState<PublicDrop[]>([]);
  const [filter, setFilter] = useState<TypeFilterValue>("all");
  const [focused, setFocused] = useState<PublicDrop | null>(null);
  const [sheet, setSheet] = useState<SheetSize>("peek");
  const focusedRef = useRef<PublicDrop | null>(null);
  const positioned = useRef(false);

  const setEngine = useCallback((next: MapEngine | null, nextStatus: MapStatus) => {
    setEngineState(next);
    setStatus(nextStatus);
  }, []);

  const focus = useCallback((drop: PublicDrop | null) => {
    focusedRef.current = drop;
    setFocused(drop);
  }, []);

  // Load the drops in view whenever the map stops moving. Without a map, list them all.
  useEffect(() => {
    let latest = 0;
    let cancelled = false;
    const load = (request: Promise<PublicDrop[]>) => {
      const ticket = ++latest;
      request.then((result) => {
        if (!cancelled && ticket === latest) setDrops(result);
      });
    };
    if (status === "unavailable") load(listPublicDrops());
    if (!engine) return () => void (cancelled = true);
    load(listDropsInBounds(engine.getBounds()));
    const off = engine.onMove((bounds) => load(listDropsInBounds(bounds)));
    return () => {
      cancelled = true;
      off();
    };
  }, [engine, status]);

  const shownDrops = useMemo(
    () => (filter === "all" ? drops : drops.filter((d) => d.type === filter)),
    [drops, filter],
  );

  // Pins: what's shown, plus the open drop even if it's filtered out or link-only.
  useEffect(() => {
    if (!engine) return;
    const pins = shownDrops.map(toPin);
    if (focused && !shownDrops.some((d) => d.id === focused.id)) pins.push(toPin(focused));
    engine.setPins(pins);
  }, [engine, shownDrops, focused]);

  useEffect(() => {
    engine?.setSelected(focused?.id ?? null);
  }, [engine, focused]);

  // Bring the open drop into view. The first time, jump there without flying.
  useEffect(() => {
    if (!engine || !focused) return;
    const zoom = Math.max(engine.getZoom(), DROP_ZOOM);
    engine.flyTo({ center: focused.placement, zoom }, { instant: !positioned.current });
    positioned.current = true;
    // Only when a different drop opens, not when its data object is recreated.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [engine, focused?.id]);

  useEffect(() => {
    if (engine) positioned.current = true;
  }, [engine]);

  useEffect(() => {
    if (!engine) return;
    return engine.onPinSelect((id) => router.push(`/d/${id}`));
  }, [engine, router]);

  // Keep the map's centre in the part of the screen the panel doesn't cover.
  const viewport = useSyncExternalStore(subscribeToResize, viewportSnapshot, () => "");
  const insets = useMemo(() => (viewport ? insetsFor(viewport, sheet) : null), [viewport, sheet]);

  useEffect(() => {
    if (engine && insets) engine.setInsets(insets);
  }, [engine, insets]);

  const value = useMemo<MapContextValue>(
    () => ({ engine, status, drops, shownDrops, filter, setFilter, focused, focus, sheet, setSheet, insets }),
    [engine, status, drops, shownDrops, filter, focused, focus, sheet, insets],
  );
  const internals = useMemo<MapInternals>(() => ({ setEngine, focusedRef }), [setEngine]);

  return (
    <InternalsContext.Provider value={internals}>
      <MapContext.Provider value={value}>{children}</MapContext.Provider>
    </InternalsContext.Provider>
  );
}
