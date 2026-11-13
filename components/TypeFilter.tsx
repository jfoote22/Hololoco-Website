"use client";

import { useState } from "react";

const options = ["All", "Offers", "Objects", "Messages"] as const;

export function TypeFilter() {
  const [selected, setSelected] = useState<(typeof options)[number]>("All");

  return (
    <div role="group" aria-label="Show" className="flex flex-wrap gap-1.5">
      {options.map((option) => (
        <button
          key={option}
          type="button"
          aria-pressed={selected === option}
          onClick={() => setSelected(option)}
          className="min-h-9 rounded-full border border-line bg-surface px-3 text-[13.5px] text-muted aria-pressed:border-accent aria-pressed:bg-accent-wash aria-pressed:font-bold aria-pressed:text-accent"
        >
          {option}
        </button>
      ))}
    </div>
  );
}
