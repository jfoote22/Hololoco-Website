"use client";

// The full-screen 3D map. It mounts once and stays mounted across routes; the panel floats over it.

import "mapbox-gl/dist/mapbox-gl.css";
import { useEffect, useRef, useState } from "react";
import { DROP_ZOOM, useMap, useMapInternals } from "@/components/map/MapProvider";
import { SAMPLE_CENTRE } from "@/lib/drops/sample";
import type { MapEngine } from "@/lib/map/engine";

const token = process.env.NEXT_PUBLIC_MAPBOX_TOKEN;

export function MapView() {
  const container = useRef<HTMLDivElement>(null);
  const { engine, status, insets, drops, placing } = useMap();
  const showsSamples = drops.some((d) => d.sample);
  const { setEngine, focusedRef } = useMapInternals();
  const [locating, setLocating] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);

  useEffect(() => {
    const el = container.current;
    if (!el) return;
    let created: MapEngine | null = null;
    let cancelled = false;

    (async () => {
      const { createMapboxEngine, webglAvailable } = await import("@/lib/map/mapbox");
      if (!token) throw new Error("NEXT_PUBLIC_MAPBOX_TOKEN is not set.");
      if (!webglAvailable()) throw new Error("This browser can't draw 3D graphics (WebGL is off).");
      const engine = await createMapboxEngine(token);
      if (cancelled) return;
      created = engine;
      const open = focusedRef.current;
      await created.mount(el, open ? { center: open.placement, zoom: DROP_ZOOM } : { center: SAMPLE_CENTRE });
      if (!cancelled) setEngine(created, "ready");
    })().catch((error: unknown) => {
      console.warn("The map couldn't start:", error);
      if (!cancelled) setEngine(null, "unavailable");
    });

    return () => {
      // Removing the map mid-load is fine; its load never finishes.
      cancelled = true;
      created?.destroy();
      setEngine(null, "loading");
    };
  }, [setEngine, focusedRef]);

  function locate() {
    if (!engine || !("geolocation" in navigator)) return;
    setLocating(true);
    setNotice(null);
    navigator.geolocation.getCurrentPosition(
      (position) => {
        setLocating(false);
        const here = { lng: position.coords.longitude, lat: position.coords.latitude };
        engine.showUserLocation(here);
        engine.flyTo({ center: here, zoom: 16.4 });
      },
      () => {
        setLocating(false);
        setNotice("Couldn't get your location. Check that this site is allowed to use it.");
      },
      { enableHighAccuracy: false, timeout: 10_000, maximumAge: 60_000 },
    );
  }

  const style = {
    "--map-inset-left": `${insets?.left ?? 0}px`,
    "--map-inset-bottom": `${insets?.bottom ?? 0}px`,
  } as React.CSSProperties;

  return (
    <section aria-label="Map" className="hl-map fixed inset-0 bg-map" style={style}>
      {/* Mapbox's stylesheet makes this position: relative, so it's sized by height, not inset. */}
      <div ref={container} className="h-full w-full" />

      {status === "loading" && (
        <p className="pointer-events-none absolute inset-0 flex items-center justify-center text-sm text-muted md:pl-[412px]">
          Loading the map…
        </p>
      )}
      {status === "unavailable" && (
        <p className="absolute top-4 right-4 max-w-[min(340px,calc(100%-32px))] rounded-lg bg-surface px-3 py-2 text-[13px] text-muted shadow-sm max-md:top-auto max-md:bottom-[calc(var(--map-inset-bottom)+12px)] max-md:left-3">
          The 3D map couldn&apos;t load here. Everything on it is still listed in the panel.
        </p>
      )}

      {status === "ready" && (
        // Sits above Mapbox's logo and attribution, which sit above the phone sheet.
        <div
          className="absolute right-3 flex flex-col items-end gap-2 transition-[bottom] duration-200 ease-out md:right-4"
          style={{ bottom: "calc(var(--map-inset-bottom, 0px) + 76px)" }}
        >
          {showsSamples && !placing && (
            <p className="rounded-md bg-surface/90 px-2 py-1 text-xs text-muted">Sample drops for testing</p>
          )}
          {notice && (
            <p role="status" className="max-w-[260px] rounded-lg bg-surface px-3 py-2 text-[13px] text-muted shadow-sm">
              {notice}
            </p>
          )}
          <MapButton label="Show my location" onClick={locate} busy={locating}>
            <path d="M12 3v3M12 18v3M3 12h3M18 12h3" />
            <circle cx="12" cy="12" r="6" />
            <circle cx="12" cy="12" r="1.6" fill="currentColor" />
          </MapButton>
          <div className="flex flex-col gap-2 max-md:hidden">
            <MapButton label="Zoom in" onClick={() => engine?.zoomBy(1)}>
              <path d="M12 5v14M5 12h14" />
            </MapButton>
            <MapButton label="Zoom out" onClick={() => engine?.zoomBy(-1)}>
              <path d="M5 12h14" />
            </MapButton>
          </div>
        </div>
      )}
    </section>
  );
}

function MapButton({
  label,
  onClick,
  busy,
  children,
}: {
  label: string;
  onClick: () => void;
  busy?: boolean;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      onClick={onClick}
      aria-busy={busy || undefined}
      className="flex size-11 items-center justify-center rounded-[10px] bg-surface text-ink shadow-[0_2px_8px_rgb(23_36_44/0.18)] hover:bg-wash aria-busy:animate-pulse"
    >
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        {children}
      </svg>
    </button>
  );
}
