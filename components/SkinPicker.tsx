"use client";

// Choosing the website's look: Daylight or Soft night, as in the app.

import { useSyncExternalStore } from "react";
import { SKINS, currentSkin, onSkinChange, setSkin } from "@/lib/skin";

export function SkinPicker() {
  const skin = useSyncExternalStore(onSkinChange, currentSkin, () => "daylight" as const);
  return (
    <fieldset className="flex flex-col gap-2">
      <legend className="mb-1 text-sm font-semibold">Look</legend>
      <div className="grid grid-cols-2 gap-2">
        {SKINS.map((option) => (
          <button
            key={option.id}
            type="button"
            aria-pressed={skin === option.id}
            onClick={() => setSkin(option.id)}
            className="flex flex-col items-start gap-2 rounded-lg border-2 border-line bg-surface p-3 text-left text-sm font-semibold hover:border-accent/60 aria-pressed:border-accent"
          >
            {option.name}
            <span className="flex gap-1" aria-hidden="true">
              {option.swatches.map((colour) => (
                <span key={colour} className="size-4 rounded-full border border-line" style={{ background: colour }} />
              ))}
            </span>
          </button>
        ))}
      </div>
    </fieldset>
  );
}
