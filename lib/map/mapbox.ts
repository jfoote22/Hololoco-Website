// Mapbox GL JS behind the MapEngine interface. Nothing outside lib/map imports Mapbox.
//
// Drops are drawn twice: as pins (buttons, so they work with a keyboard and screen
// readers) and, when zoomed in close, as their 3D model at real height, size and turn
// through Mapbox's own model layer. Keeping models to close zoom keeps phones smooth.

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
  private pins = new Map<string, PinEntry>();
  private selected: string | null = null;
  private pinHandlers = new Set<(id: string) => void>();
  private models = new Set<string>();
  private me: Marker | null = null;
  private modelsShown: boolean | null = null;
  private pinsChanged = false;

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
          // A quiet, light, desaturated base so people's content is the colour on screen.
          config: {
            basemap: {
              lightPreset: "day",
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
        console.warn("Map:", event.error?.message ?? event.error);
      });
      map.on("load", () => {
        loaded = true;
        if (process.env.NODE_ENV === "development") Object.assign(window, { __hlMap: map, __hlEngine: this });
        this.addModelLayer(map);
        map.on("zoom", () => this.placePinsOnModels());
        resolve();
      });
      this.map = map;
    });
  }

  destroy() {
    for (const { marker } of this.pins.values()) marker.remove();
    this.pins.clear();
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
      if (existing) {
        existing.marker.setLngLat([pin.placement.lng, pin.placement.lat]);
        existing.pin = pin;
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

    const features = pins.flatMap((pin) => {
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
          id: pin.id,
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

    const stem = document.createElement("span");
    stem.className = "hl-pin-stem";
    const foot = document.createElement("span");
    foot.className = "hl-pin-foot";

    el.append(label, head, stem, foot);
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
      { maxZoom: options.maxZoom ?? 16, duration: 1400 },
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

  pickLocation(): Promise<LngLat | null> {
    const map = this.map;
    if (!map) return Promise.resolve(null);
    return new Promise((resolve) => {
      const canvas = map.getCanvasContainer();
      const finish = (value: LngLat | null) => {
        map.off("click", onClick);
        window.removeEventListener("keydown", onKey);
        canvas.style.cursor = "";
        resolve(value);
      };
      const onClick = (event: { lngLat: { lng: number; lat: number } }) =>
        finish({ lng: event.lngLat.lng, lat: event.lngLat.lat });
      const onKey = (event: KeyboardEvent) => {
        if (event.key === "Escape") finish(null);
      };
      canvas.style.cursor = "crosshair";
      map.on("click", onClick);
      window.addEventListener("keydown", onKey);
    });
  }
}
