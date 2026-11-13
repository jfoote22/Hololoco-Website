"use client";

import { useMap, type TypeFilterValue } from "@/components/map/MapProvider";

const options: { value: TypeFilterValue; label: string }[] = [
  { value: "all", label: "All" },
  { value: "object", label: "Objects" },
  { value: "offer", label: "Offers" },
  { value: "message", label: "Messages" },
];

/** Shows one type of drop on the map and in the list, or all of them. */
export function TypeFilter() {
  const { filter, setFilter } = useMap();

  return (
    <div
      role="group"
      aria-label="Show"
      className="grid grid-cols-4 gap-0.5 rounded-[10px] bg-wash p-[3px] max-md:bg-surface max-md:shadow-[0_4px_16px_rgb(23_36_44/0.12)]"
    >
      {options.map((option) => (
        <button
          key={option.value}
          type="button"
          aria-pressed={filter === option.value}
          onClick={() => setFilter(option.value)}
          className="min-h-10 rounded-lg text-sm font-medium text-muted hover:text-ink aria-pressed:bg-surface aria-pressed:font-semibold aria-pressed:text-ink aria-pressed:shadow-[0_1px_3px_rgb(23_36_44/0.14)] max-md:aria-pressed:bg-wash max-md:aria-pressed:shadow-none"
        >
          {option.label}
        </button>
      ))}
    </div>
  );
}
