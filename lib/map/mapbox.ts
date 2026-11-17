// Mapbox GL JS behind the MapEngine interface. Nothing outside lib/map imports Mapbox.
//
// Drops are drawn twice: as pins (buttons, so they work with a keyboard and screen
// readers) and, when zoomed in close, as their 3D model at real height, size and turn
// through Mapbox's own model layer. Keeping models to close zoom keeps phones smooth.

import { currentSkin } from "@/lib/skin";
import type { ExpressionSpecification, GeoJSONSource, Map as MapboxMap, Marker } from "mapbox-gl";
import type { Insets, LngLat, MapBounds, MapEngine, MapPin, View } from "./engine";

type MapboxGL = typeof import("mapbox-gl").default;

/** Models fade in from this zoom; further out there are only pins. Keeps phones smooth. */
const MODEL_MIN_ZOOM = 15.5;

/**
 * How big a model is drawn on the map, in metres. A 6 m object is a few pixels across
 * from a block away, so the map draws objects larger than life (6 m shows as 24 m) while
 * keeping bigger ones bigger. Their true size is kept in the drop for AR later.
 * (Mapbox can't scale a model by zoom per drop reliably, so this is one size at every zoom.)
 */
export function shownSize(size: number): number {
  return size * 2 + 12;
}

const SOURCE = "hl-drops";
const MODEL_LAYER = "hl-drop-models";
const ROUTE_SOURCE = "hl-route";
const ROUTE_LAYER = "hl-route-line";

export const DEFAULT_VIEW = { zoom: 16.4, pitch: 58, bearing: -20 };

export function webglAvailable(): boolean {
  try {
    const canvas = document.createElement("canvas");
    return Boolean(canvas.getContext("webgl2") ?? canvas.getContext("webgl"));
  } catch {
    return false;
  }
}

export async function createMapboxEngine(accessToken: string): Promise<MapEngine> {
  const mapboxgl = (await import("mapbox-gl")).default;
  return new MapboxEngine(mapboxgl, accessToken);
}

type PinEntry = { marker: Marker; el: HTMLButtonElement; pin: MapPin };

class MapboxEngine implements MapEngine {
  private map: MapboxMap | null = null;
  private look: "day" | "night" = currentSkin() === "soft-night" ? "night" : "day";
  private pins = new Map<string, PinEntry>();
  private selected: string | null = null;
  private pinHandlers = new Set<(id: string) => void>();
  private models = new Set<string>();
  private me: Marker | null = null;
  private modelsShown: boolean | null = null;
  private pinsChanged = false;
  private shownPins: MapPin[] = [];
  private draft: { pin: MapPin; marker: Marker } | null = null;
  private draftHandlers = new Set<(at: LngLat) => void>();

  constructor(
    private gl: MapboxGL,
    private accessToken: string,
  ) {}

  mount(container: HTMLElement, view: View): Promise<void> {
    return new Promise((resolve, reject) => {
      let map: MapboxMap;
      try {
        map = new this.gl.Map({
          accessToken: this.accessToken,
          container,
          style: "mapbox://styles/mapbox/standard",
          // A quiet, desaturated base so people's content is the colour on screen,
          // in day or night light to match the website's look.
          config: {
            basemap: {
              lightPreset: this.look,
              theme: "faded",
              showPointOfInterestLabels: false,
              showTransitLabels: false,
            },
          },
          center: [view.center.lng, view.center.lat],
          zoom: view.zoom ?? DEFAULT_VIEW.zoom,
          pitch: view.pitch ?? DEFAULT_VIEW.pitch,
          bearing: view.bearing ?? DEFAULT_VIEW.bearing,
          maxPitch: 70,
          attributionControl: false,
          logoPosition: "bottom-right",
        });
      } catch (error) {
        reject(error);
        return;
      }

      map.addControl(new this.gl.AttributionControl({ compact: true }), "bottom-right");

      let loaded = false;
      map.on("error", (event) => {
        const status = (event.error as { status?: number } | undefined)?.status;
        if (!loaded && (status === 401 || status === 403)) {
          reject(new Error("The map token was refused."));
          map.remove();
          this.map = null;
          return;
        }
        const cause = (event.error as { cause?: unknown } | undefined)?.cause;
        console.warn("Map:", event.error?.message ?? event.error, cause ?? "");
      });
      map.on("load", () => {
        loaded = true;
        if (process.env.NODE_ENV === "development") Object.assign(window, { __hlMap: map, __hlEngine: this });
        this.addModelLayer(map);
        this.addRouteLayer(map);
        map.on("zoom", () => this.placePinsOnModels());
        resolve();
      });
      this.map = map;
    });
  }

  setLook(look: "day" | "night") {
    if (look === this.look) return;
    this.look = look;
    this.map?.setConfigProperty("basemap", "lightPreset", look);
  }

  destroy() {
    for (const { marker } of this.pins.values()) marker.remove();
    this.pins.clear();
    this.draft?.marker.remove();
    this.draft = null;
    this.me?.remove();
    this.map?.remove();
    this.map = null;
  }

  private addModelLayer(map: MapboxMap) {
    map.addSource(SOURCE, { type: "geojson", data: { type: "FeatureCollection", features: [] } });
    map.addLayer({
      id: MODEL_LAYER,
      type: "model",
      source: SOURCE,
      minzoom: MODEL_MIN_ZOOM,
      layout: { "model-id": ["get", "model"] },
      paint: {
        "model-type": "common-3d",
        "model-scale": ["get", "scale"] as ExpressionSpecification,
        "model-rotation": ["get", "rotation"],
        "model-translation": ["get", "translation"],
        "model-opacity": ["interpolate", ["linear"], ["zoom"], MODEL_MIN_ZOOM, 0, MODEL_MIN_ZOOM + 0.4, 1],
        "model-emissive-strength": 0.35,
      },
    });
  }

  /** A dashed line joining a quest's stages, drawn on the ground under the pins. */
  private addRouteLayer(map: MapboxMap) {
    map.addSource(ROUTE_SOURCE, { type: "geojson", data: { type: "FeatureCollection", features: [] } });
    map.addLayer({
      id: ROUTE_LAYER,
      type: "line",
      source: ROUTE_SOURCE,
      layout: { "line-join": "round", "line-cap": "round" },
      paint: {
        "line-color": "#006d7a",
        "line-width": ["interpolate", ["linear"], ["zoom"], 12, 3, 17, 6],
        "line-dasharray": [1.5, 1.5],
        "line-opacity": 0.85,
        "line-emissive-strength": 1,
      },
    });
  }

  setRoute(points: LngLat[] | null) {
    const source = this.map?.getSource(ROUTE_SOURCE) as GeoJSONSource | undefined;
    if (!source) return;
    source.setData({
      type: "FeatureCollection",
      features:
        points && points.length > 1
          ? [
              {
                type: "Feature",
                properties: {},
                geometry: { type: "LineString", coordinates: points.map((p) => [p.lng, p.lat]) },
              },
            ]
          : [],
    });
  }

  setPins(pins: MapPin[]) {
    const map = this.map;
    if (!map) return;

    const keep = new Set(pins.map((p) => p.id));
    for (const [id, entry] of this.pins) {
      if (!keep.has(id)) {
        entry.marker.remove();
        this.pins.delete(id);
      }
    }

    for (const pin of pins) {
      const existing = this.pins.get(pin.id);
      // A pin that now says something else is drawn again.
      if (existing && (existing.pin.count !== pin.count || existing.pin.title !== pin.title || existing.pin.thumbnail !== pin.thumbnail)) {
        existing.marker.remove();
        this.pins.delete(pin.id);
      } else if (existing) {
        existing.marker.setLngLat([pin.placement.lng, pin.placement.lat]);
        existing.pin = pin;
        setFaint(existing.el, pin.faint === true);
        continue;
      }
      const el = this.pinElement(pin);
      const marker = new this.gl.Marker({ element: el, anchor: "bottom", offset: [0, 4], occludedOpacity: 0.35 })
        .setLngLat([pin.placement.lng, pin.placement.lat])
        .addTo(map);
      this.pins.set(pin.id, { marker, el, pin });
    }
    this.applySelected();
    this.pinsChanged = true;
    this.placePinsOnModels();
    this.shownPins = pins;
    this.drawModels();
  }

  /** One source holds every model: the drops shown, plus the draft. */
  private drawModels() {
    const map = this.map;
    if (!map) return;
    const all = this.draft ? [...this.shownPins, this.draft.pin] : this.shownPins;
    const features = all.flatMap((pin) => {
      if (!pin.modelUrl) return [];
      const url = new URL(pin.modelUrl, window.location.href).href;
      if (!this.models.has(url)) {
        map.addModel(url, url);
        this.models.add(url);
      }
      const { lng, lat, size, height, turn } = pin.placement;
      const s = shownSize(size);
      return [
        {
          type: "Feature" as const,
          geometry: { type: "Point" as const, coordinates: [lng, lat] },
          properties: {
            model: url,
            scale: [s, s, s],
            rotation: [0, 0, turn],
            translation: [0, 0, height],
          },
        },
      ];
    });
    (map.getSource(SOURCE) as GeoJSONSource | undefined)?.setData({ type: "FeatureCollection", features });
  }

  setDraft(pin: MapPin | null) {
    const map = this.map;
    if (!map) return;
    if (!pin) {
      this.draft?.marker.remove();
      this.draft = null;
      this.drawModels();
      return;
    }
    const at: [number, number] = [pin.placement.lng, pin.placement.lat];
    if (this.draft) {
      this.draft.pin = pin;
      this.draft.marker.setLngLat(at);
    } else {
      // A handle on the ground, so the model above it stays in view.
      const marker = new this.gl.Marker({ element: this.draftElement(), anchor: "top", offset: [0, -18], draggable: true })
        .setLngLat(at)
        .addTo(map);
      // The model follows the pin while it's dragged; the add flow hears where it ends up.
      marker.on("drag", () => {
        if (!this.draft) return;
        const { lng, lat } = marker.getLngLat();
        this.draft.pin = { ...this.draft.pin, placement: { ...this.draft.pin.placement, lng, lat } };
        this.drawModels();
      });
      marker.on("dragend", () => {
        const { lng, lat } = marker.getLngLat();
        for (const handler of this.draftHandlers) handler({ lng, lat });
      });
      this.draft = { pin, marker };
    }
    this.drawModels();
  }

  private draftElement(): HTMLElement {
    const el = document.createElement("div");
    el.className = "hl-draft";
    el.setAttribute("role", "img");
    el.setAttribute("aria-label", "Your drop. Drag to move it.");
    el.innerHTML =
      '<span class="hl-draft-handle" aria-hidden="true">' +
      '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
      '<path d="M12 3v18M3 12h18M12 3l-3 3M12 3l3 3M12 21l-3-3M12 21l3-3M3 12l3-3M3 12l3 3M21 12l-3-3M21 12l-3 3"/></svg></span>' +
      '<span class="hl-draft-label" aria-hidden="true">Drag to move</span>';
    // A tap on the handle isn't a tap on the map behind it.
    el.addEventListener("click", (event) => event.stopPropagation());
    return el;
  }

  onDraftMove(handler: (at: LngLat) => void) {
    this.draftHandlers.add(handler);
    return () => {
      this.draftHandlers.delete(handler);
    };
  }

  onMapTap(handler: (at: LngLat) => void) {
    const map = this.map;
    if (!map) return () => {};
    const canvas = map.getCanvasContainer();
    const listener = (event: { lngLat: { lng: number; lat: number } }) =>
      handler({ lng: event.lngLat.lng, lat: event.lngLat.lat });
    map.on("click", listener);
    canvas.style.cursor = "crosshair";
    return () => {
      map.off("click", listener);
      canvas.style.cursor = "";
    };
  }

  /** While models show, each pin stands on top of its model instead of covering it. */
  private placePinsOnModels() {
    const zoom = this.map?.getZoom();
    if (zoom === undefined) return;
    const modelsShown = zoom >= MODEL_MIN_ZOOM;
    if (modelsShown === this.modelsShown && !this.pinsChanged) return;
    this.modelsShown = modelsShown;
    this.pinsChanged = false;
    for (const { marker, pin } of this.pins.values()) {
      const { height, size } = pin.placement;
      marker.setAltitude(pin.modelUrl && modelsShown ? height + shownSize(size) : 0);
    }
  }

  private pinElement(pin: MapPin): HTMLButtonElement {
    const el = document.createElement("button");
    el.type = "button";
    el.className = "hl-pin";
    el.dataset.type = pin.type;
    el.setAttribute("aria-label", pin.title);

    const label = document.createElement("span");
    label.className = "hl-pin-label";
    label.setAttribute("aria-hidden", "true");
    label.textContent = pin.title;

    const head = document.createElement("span");
    head.className = "hl-pin-head";
    if (pin.thumbnail) {
      const img = document.createElement("img");
      img.src = pin.thumbnail;
      img.alt = "";
      img.draggable = false;
      img.decoding = "async";
      head.append(img);
    }
    if (pin.count && pin.count > 1) {
      const count = document.createElement("span");
      count.className = "hl-pin-count";
      count.textContent = pin.count > 99 ? "99+" : String(pin.count);
      head.append(count);
    }

    const stem = document.createElement("span");
    stem.className = "hl-pin-stem";
    const foot = document.createElement("span");
    foot.className = "hl-pin-foot";

    el.append(label, head, stem, foot);
    setFaint(el, pin.faint === true);
    el.addEventListener("click", (event) => {
      event.stopPropagation();
      for (const handler of this.pinHandlers) handler(pin.id);
    });
    return el;
  }

  setSelected(id: string | null) {
    this.selected = id;
    this.applySelected();
  }

  private applySelected() {
    for (const [id, { el }] of this.pins) {
      const on = id === this.selected;
      el.classList.toggle("is-selected", on);
      if (on) el.setAttribute("aria-current", "true");
      else el.removeAttribute("aria-current");
      el.style.zIndex = on ? "2" : "";
    }
  }

  flyTo(view: View, options: { instant?: boolean } = {}) {
    const map = this.map;
    if (!map) return;
    const camera = {
      center: [view.center.lng, view.center.lat] as [number, number],
      zoom: view.zoom ?? map.getZoom(),
      pitch: view.pitch ?? map.getPitch(),
      bearing: view.bearing ?? map.getBearing(),
    };
    if (options.instant) map.jumpTo(camera);
    else map.flyTo({ ...camera, duration: 1400 });
  }

  fitBounds(bounds: MapBounds, options: { maxZoom?: number } = {}) {
    this.map?.fitBounds(
      [
        [bounds.west, bounds.south],
        [bounds.east, bounds.north],
      ],
      // Mapbox flattens the view when fitting unless told otherwise; keep the 3D tilt.
      { maxZoom: options.maxZoom ?? 16, duration: 1400, pitch: this.map.getPitch(), bearing: this.map.getBearing() },
    );
  }

  zoomBy(delta: number) {
    const map = this.map;
    if (map) map.easeTo({ zoom: map.getZoom() + delta, duration: 250 });
  }

  getZoom() {
    return this.map?.getZoom() ?? DEFAULT_VIEW.zoom;
  }

  setInsets(insets: Insets) {
    this.map?.setPadding(insets);
  }

  getBounds(): MapBounds {
    const b = this.map?.getBounds();
    if (!b) return { west: 0, south: 0, east: 0, north: 0 };
    return { west: b.getWest(), south: b.getSouth(), east: b.getEast(), north: b.getNorth() };
  }

  getCenter(): LngLat {
    const c = this.map?.getCenter();
    return { lng: c?.lng ?? 0, lat: c?.lat ?? 0 };
  }

  onMove(handler: (bounds: MapBounds) => void) {
    const map = this.map;
    if (!map) return () => {};
    const listener = () => handler(this.getBounds());
    map.on("moveend", listener);
    return () => {
      map.off("moveend", listener);
    };
  }

  onPinSelect(handler: (id: string) => void) {
    this.pinHandlers.add(handler);
    return () => {
      this.pinHandlers.delete(handler);
    };
  }

  showUserLocation(at: LngLat | null) {
    const map = this.map;
    if (!map) return;
    if (!at) {
      this.me?.remove();
      this.me = null;
      return;
    }
    if (!this.me) {
      const el = document.createElement("span");
      el.className = "hl-me";
      el.setAttribute("aria-label", "You are here");
      el.setAttribute("role", "img");
      this.me = new this.gl.Marker({ element: el }).setLngLat([at.lng, at.lat]).addTo(map);
    } else {
      this.me.setLngLat([at.lng, at.lat]);
    }
  }
}

/** Someone else's pin: dimmed, and out of reach of clicks, keys and screen readers. */
function setFaint(el: HTMLButtonElement, faint: boolean) {
  el.classList.toggle("is-faint", faint);
  el.disabled = faint;
  if (faint) el.setAttribute("aria-hidden", "true");
  else el.removeAttribute("aria-hidden");
}
