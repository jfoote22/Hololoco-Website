import type { Metadata } from "next";
import { Suspense } from "react";
import { SheetHeight } from "@/components/map/SheetHeight";
import { YourDrops } from "@/components/mine/YourDrops";

export const metadata: Metadata = { title: "Your drops", robots: { index: false } };

// Runs in the browser: the person's session lives there, and the database decides what they can see.
export default function YourDropsScreen() {
  return (
    <>
      <SheetHeight size="half" />
      <Suspense fallback={<p className="text-sm text-muted">Loading…</p>}>
        <YourDrops />
      </Suspense>
    </>
  );
}
