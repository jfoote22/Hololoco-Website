"use client";

// Shared state between the map and the panel: the signed-in person's own drops,
// other people's public drops around them, the drop being looked at, and how tall
// the phone sheet is. The map stays mounted across every route, so this lives in
// the root layout.
//
// The website is where businesses place and manage content; people find it in the
// Hololoco app. So the map shows your own drops in every state, and other people's
// only faintly, as context for where yours go.

import { usePathname, useRouter } from "next/navigation";
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
import { useSession } from "@/components/auth/session";
import { attachPreviews } from "@/lib/assets";
import { modelFor, thumbnailFor } from "@/lib/drops/format";
import { listMyDrops } from "@/lib/drops/mine";
import { listDropsInBounds } from "@/lib/drops/source";
import type { MyDrop, PublicDrop } from "@/lib/drops/types";
import type { Insets, MapEngine, MapPin } from "@/lib/map/engine";

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
  /** The signed-in person's own drops, in every state. Empty when signed out. */
  mine: MyDrop[];
  /** Other people's public drops in the visible area, shown faintly. Empty when signed out. */
  others: PublicDrop[];
  /** The drop being looked at, if any. */
  focused: PublicDrop | null;
  focus: (drop: PublicDrop | null) => void;
  sheet: SheetSize;
  setSheet: (size: SheetSize) => void;
  insets: Insets | null;
  /** The add flow's drop while it's being placed. */
  setDraft: (draft: MapPin | null) => void;
  /** True while the add flow has a drop on the map. */
  placing: boolean;
  /** Load the drops again, e.g. after publishing, pausing or deleting one. */
  reload: () => void;
};

type MapInternals = {
  setEngine: (engine: MapEngine | null, status: MapStatus) => void;
  /** The drop to open the map on, when a screen focuses one before the map loads. */
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

const NONE: never[] = [];

export function MapProvider({ children }: { children: React.ReactNode }) {
  const router = useRouter();
  const pathname = usePathname();
  const session = useSession();
  const userId = session.status === "signed-in" ? session.user.id : null;
  const [engine, setEngineState] = useState<MapEngine | null>(null);
  const [status, setStatus] = useState<MapStatus>("loading");
  const [loadedMine, setLoadedMine] = useState<{ userId: string; drops: MyDrop[] } | null>(null);
  const [loadedOthers, setLoadedOthers] = useState<PublicDrop[]>([]);
  const [focused, setFocused] = useState<PublicDrop | null>(null);
  const [sheet, setSheet] = useState<SheetSize>("peek");
  const [draft, setDraft] = useState<MapPin | null>(null);
  const [reloads, setReloads] = useState(0);
  const reload = useCallback(() => setReloads((n) => n + 1), []);
  const focusedRef = useRef<PublicDrop | null>(null);
  const positioned = useRef(false);
  const fittedFor = useRef<string | null>(null);

  // Signing out empties both at once; nothing of the last person's lingers.
  const mine = userId && loadedMine?.userId === userId ? loadedMine.drops : NONE;
  const others = userId ? loadedOthers : NONE;

  const setEngine = useCallback((next: MapEngine | null, nextStatus: MapStatus) => {
    setEngineState(next);
    setStatus(nextStatus);
  }, []);

  const focus = useCallback((drop: PublicDrop | null) => {
    focusedRef.current = drop;
    setFocused(drop);
  }, []);

  // The person's own drops, with signed links to uploads that aren't public yet.
  useEffect(() => {
    if (!userId) return;
    let cancelled = false;
    listMyDrops()
      .then(attachPreviews)
      .then((drops) => !cancelled && setLoadedMine({ userId, drops }))
      .catch((error: unknown) => console.warn("Couldn't load your drops for the map:", error));
    return () => {
      cancelled = true;
    };
  }, [userId, reloads]);

  // Everyone else's, in the visible area, whenever the map stops moving.
  useEffect(() => {
    if (!engine || !userId) return;
    let latest = 0;
    let cancelled = false;
    const load = (request: Promise<PublicDrop[]>) => {
      const ticket = ++latest;
      request.then((result) => {
        if (!cancelled && ticket === latest) setLoadedOthers(result);
      });
    };
    load(listDropsInBounds(engine.getBounds()));
    const off = engine.onMove((bounds) => load(listDropsInBounds(bounds)));
    return () => {
      cancelled = true;
      off();
    };
  }, [engine, userId, reloads]);

  // Pins: other people's faintly and without their models, then your own, then the
  // drop being looked at. A drop being edited shows only as the draft.
  useEffect(() => {
    if (!engine) return;
    const pins = new Map<string, MapPin>();
    for (const drop of others) pins.set(drop.id, { ...toPin(drop), modelUrl: undefined, faint: true });
    for (const drop of mine) pins.set(drop.id, toPin(drop));
    if (focused) pins.set(focused.id, toPin(focused));
    if (draft) pins.delete(draft.id);
    engine.setPins([...pins.values()]);
  }, [engine, others, mine, focused, draft]);

  useEffect(() => {
    engine?.setDraft(draft);
  }, [engine, draft]);

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

  // On the start page, open on the person's own drops the first time they load.
  useEffect(() => {
    if (!engine || !userId || pathname !== "/" || focusedRef.current) return;
    if (fittedFor.current === userId || loadedMine?.userId !== userId || loadedMine.drops.length === 0) return;
    fittedFor.current = userId;
    const lats = loadedMine.drops.map((d) => d.placement.lat);
    const lngs = loadedMine.drops.map((d) => d.placement.lng);
    engine.fitBounds(
      { west: Math.min(...lngs), south: Math.min(...lats), east: Math.max(...lngs), north: Math.max(...lats) },
      { maxZoom: 16.4 },
    );
  }, [engine, userId, pathname, loadedMine]);

  useEffect(() => {
    if (engine) positioned.current = true;
  }, [engine]);

  // Only your own pins can be clicked (the others are faint); one opens it for editing.
  useEffect(() => {
    if (!engine) return;
    const ids = new Set(mine.map((d) => d.id));
    return engine.onPinSelect((id) => {
      if (ids.has(id)) router.push(`/add?edit=${id}`);
    });
  }, [engine, router, mine]);

  // Keep the map's centre in the part of the screen the panel doesn't cover.
  const viewport = useSyncExternalStore(subscribeToResize, viewportSnapshot, () => "");
  const insets = useMemo(() => (viewport ? insetsFor(viewport, sheet) : null), [viewport, sheet]);

  useEffect(() => {
    if (engine && insets) engine.setInsets(insets);
  }, [engine, insets]);

  const value = useMemo<MapContextValue>(
    () => ({
      engine,
      status,
      mine,
      others,
      focused,
      focus,
      sheet,
      setSheet,
      insets,
      setDraft,
      placing: draft !== null,
      reload,
    }),
    [engine, status, mine, others, focused, focus, sheet, insets, draft, reload],
  );
  const internals = useMemo<MapInternals>(() => ({ setEngine, focusedRef }), [setEngine]);

  return (
    <InternalsContext.Provider value={internals}>
      <MapContext.Provider value={value}>{children}</MapContext.Provider>
    </InternalsContext.Provider>
  );
}
