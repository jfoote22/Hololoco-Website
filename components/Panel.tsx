"use client";

// The one floating panel. Desktop: on the left, 380 px wide, full height.
// Phone: a bottom sheet with three heights (peek, half, full). Drag the handle or tap it.
// Pages set the height they open at with <SheetHeight />.

import Link from "next/link";
import { Suspense, useRef, useState } from "react";
import { BackToMap } from "@/components/BackToMap";
import { sheetPixels, useMap, type SheetSize } from "@/components/map/MapProvider";

const ORDER: SheetSize[] = ["peek", "half", "full"];

// Keep in step with sheetPixels() in MapProvider.
const HEIGHT_CLASS: Record<SheetSize, string> = {
  peek: "max-md:h-[188px]",
  half: "max-md:h-[55dvh]",
  full: "max-md:h-[calc(100dvh-128px)]",
};

export function Panel({ children }: { children: React.ReactNode }) {
  const { sheet, setSheet } = useMap();
  const panel = useRef<HTMLElement>(null);
  const drag = useRef<{ startY: number; startHeight: number; moved: boolean } | null>(null);
  const dragged = useRef(false);
  const [dragHeight, setDragHeight] = useState<number | null>(null);

  function onPointerDown(event: React.PointerEvent<HTMLButtonElement>) {
    if (event.button !== 0 || !panel.current) return;
    drag.current = { startY: event.clientY, startHeight: panel.current.offsetHeight, moved: false };
    event.currentTarget.setPointerCapture(event.pointerId);
  }

  function onPointerMove(event: React.PointerEvent<HTMLButtonElement>) {
    const d = drag.current;
    if (!d) return;
    const dy = event.clientY - d.startY;
    if (!d.moved && Math.abs(dy) < 6) return;
    d.moved = true;
    const vh = window.innerHeight;
    const min = sheetPixels("peek", vh) - 40;
    const max = sheetPixels("full", vh);
    setDragHeight(Math.min(max, Math.max(min, d.startHeight - dy)));
  }

  function onPointerUp() {
    const d = drag.current;
    drag.current = null;
    if (!d?.moved || dragHeight === null) return;
    dragged.current = true;
    const vh = window.innerHeight;
    const nearest = ORDER.reduce((best, size) =>
      Math.abs(sheetPixels(size, vh) - dragHeight) < Math.abs(sheetPixels(best, vh) - dragHeight) ? size : best,
    );
    setDragHeight(null);
    setSheet(nearest);
  }

  function onClick() {
    // A drag ends with a click on the same button; only a tap or a key press cycles the height.
    if (dragged.current) {
      dragged.current = false;
      return;
    }
    setSheet(ORDER[(ORDER.indexOf(sheet) + 1) % ORDER.length]);
  }

  return (
    <aside
      ref={panel}
      aria-label="Panel"
      style={dragHeight === null ? undefined : { height: dragHeight }}
      className={`fixed inset-x-0 bottom-0 z-10 flex flex-col rounded-t-2xl bg-surface shadow-(--shadow-panel) md:inset-x-auto md:top-4 md:bottom-4 md:left-4 md:w-[380px] md:rounded-(--radius-panel) ${HEIGHT_CLASS[sheet]} ${dragHeight === null ? "transition-[height] duration-200 ease-out motion-reduce:transition-none" : ""}`}
    >
      <button
        type="button"
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerUp}
        onClick={onClick}
        aria-label={sheet === "full" ? "Make the panel smaller" : "Make the panel bigger"}
        className="flex h-5 w-full shrink-0 cursor-grab touch-none items-end justify-center md:hidden"
      >
        <span className="h-1 w-10 rounded-full bg-line" aria-hidden="true" />
      </button>
      <header className="flex shrink-0 items-center justify-between px-4 md:pt-3">
        <Link href="/" className="flex min-h-11 items-center gap-2 font-display text-xl font-bold tracking-tight">
          <Logo />
          hololoco
        </Link>
        <Link href="/mine" className="flex min-h-11 items-center px-2 text-sm font-medium text-muted hover:text-ink">
          Your drops
        </Link>
      </header>
      <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto overscroll-contain px-4 pt-2 pb-4">
        {/* Reading the address waits on a drop page's id, so this mustn't hold up the rest. */}
        <Suspense fallback={null}>
          <BackToMap />
        </Suspense>
        {children}
      </div>
    </aside>
  );
}

function Logo() {
  return (
    <svg width="22" height="30" viewBox="0 0 22 30" aria-hidden="true">
      <circle cx="11" cy="11" r="8.5" fill="none" stroke="var(--color-accent)" strokeWidth="4" />
      <rect x="10" y="20" width="2" height="9" fill="var(--color-accent)" />
    </svg>
  );
}
