// The app talks to the map only through this interface, so the vendor can change
// (Mapbox at launch; another 3D map later if cost or quality calls for it).
// lib/map/mapbox.ts implements it.

import type { DropType, Placement } from "@/lib/drops/types";

export type LngLat = { lng: number; lat: number };

export type MapBounds = { west: number; south: number; east: number; north: number };

/** Space covered by the panel, in CSS pixels, so the map centres things in the open part. */
export type Insets = { top: number; right: number; bottom: number; left: number };

export type View = { center: LngLat; zoom?: number; pitch?: number; bearing?: number };

export type MapPin = {
  id: string;
  type: DropType;
  title: string;
  placement: Placement;
  /** Small picture for the pin. */
  thumbnail?: string;
  /** GLB shown at its real place, height, size and turn when zoomed in close. */
  modelUrl?: string;
};

export interface MapEngine {
  /** Attach the map to a container element and resolve once it can draw. */
  mount(container: HTMLElement, view: View): Promise<void>;
  destroy(): void;

  /** Replace every pin on the map. */
  setPins(pins: MapPin[]): void;
  /** Highlight one pin, or none. */
  setSelected(id: string | null): void;

  /** Move the camera. `instant` skips the animation. */
  flyTo(view: View, options?: { instant?: boolean }): void;
  fitBounds(bounds: MapBounds, options?: { maxZoom?: number }): void;
  zoomBy(delta: number): void;
  getZoom(): number;
  setInsets(insets: Insets): void;

  /** The visible area. It is the only location the server ever receives. */
  getBounds(): MapBounds;
  getCenter(): LngLat;
  /** Called after the map stops moving. */
  onMove(handler: (bounds: MapBounds) => void): () => void;
  onPinSelect(handler: (id: string) => void): () => void;

  /** Shows where the person is. Their location stays in the browser. */
  showUserLocation(at: LngLat | null): void;

  /** Placement mode for the add flow: the next tap on the map picks a spot. */
  pickLocation(): Promise<LngLat | null>;
}
