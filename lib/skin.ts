// The website's look, matching the app's skins: Daylight (the default) and Soft night.
// The choice is kept in this browser and set as data-skin on <html>, where
// app/globals.css swaps the colour and font tokens. The map follows it too.

export type SkinId = "daylight" | "soft-night";

export const SKINS: { id: SkinId; name: string; blurb: string; swatches: [string, string, string] }[] = [
  { id: "daylight", name: "Daylight", blurb: "Bright and easy to read.", swatches: ["#f2f5f7", "#00788a", "#f2b13a"] },
  { id: "soft-night", name: "Soft night", blurb: "Calm and dark.", swatches: ["#0b1020", "#7fe3f2", "#f7a8f0"] },
];

const KEY = "hl.skin";
const EVENT = "hl-skin";

/** Runs before the page draws (see app/layout.tsx), so a saved Soft night never flashes light first. */
export const SKIN_SCRIPT = `try{var s=localStorage.getItem("${KEY}");if(s==="soft-night")document.documentElement.dataset.skin=s}catch(e){}`;

export function currentSkin(): SkinId {
  if (typeof document === "undefined") return "daylight";
  return document.documentElement.dataset.skin === "soft-night" ? "soft-night" : "daylight";
}

export function setSkin(id: SkinId) {
  try {
    localStorage.setItem(KEY, id);
  } catch {
    // Private windows can refuse storage; the look still changes for this visit.
  }
  if (id === "daylight") delete document.documentElement.dataset.skin;
  else document.documentElement.dataset.skin = id;
  window.dispatchEvent(new Event(EVENT));
}

export function onSkinChange(listener: () => void): () => void {
  window.addEventListener(EVENT, listener);
  return () => window.removeEventListener(EVENT, listener);
}
