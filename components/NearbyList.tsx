"use client";

import Link from "next/link";
import { DropThumb } from "@/components/DropThumb";
import { useMap } from "@/components/map/MapProvider";
import { byline } from "@/lib/drops/format";
import type { DropType } from "@/lib/drops/types";

const plural: Record<DropType | "all", [string, string]> = {
  all: ["drop", "drops"],
  object: ["object", "objects"],
  offer: ["offer", "offers"],
  message: ["message", "messages"],
};

/** Every drop in view, as a list. It's also how screen reader users reach each pin. */
export function NearbyList() {
  const { shownDrops, status, filter } = useMap();
  const [one, many] = plural[filter];
  const count = shownDrops.length;

  const heading =
    status === "loading"
      ? "Looking for drops…"
      : status === "unavailable"
        ? `${count} ${count === 1 ? one : many} in the sample area`
        : `${count} ${count === 1 ? one : many} in this view`;

  return (
    <section aria-labelledby="nearby-heading" className="flex flex-col gap-0.5 border-t border-line pt-3 max-md:border-0 max-md:pt-0">
      <h2 id="nearby-heading" className="mb-1.5 font-sans text-[13px] font-semibold text-muted">
        {heading}
      </h2>
      {status !== "loading" && count === 0 && (
        <p className="rounded-(--radius-panel) border border-dashed border-line px-4 py-5 text-center text-sm text-muted">
          Nothing here yet. Zoom out or search another place.
        </p>
      )}
      <ul className="flex flex-col gap-0.5">
        {shownDrops.map((drop) => (
          <li key={drop.id}>
            <Link
              href={`/d/${drop.id}`}
              className="-mx-2 flex min-h-16 items-center gap-3 rounded-[10px] p-2 hover:bg-wash"
            >
              <DropThumb drop={drop} />
              <span className="flex min-w-0 flex-col gap-0.5">
                <span className="truncate text-[15px] font-semibold text-ink">{drop.title}</span>
                <span className="truncate text-[13px] text-muted">{byline(drop)}</span>
              </span>
            </Link>
          </li>
        ))}
      </ul>
    </section>
  );
}
