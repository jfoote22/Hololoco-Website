import type { Metadata } from "next";
import { Suspense } from "react";
import { YourEvents } from "@/components/events/YourEvents";
import { SheetHeight } from "@/components/map/SheetHeight";

export const metadata: Metadata = { title: "Events", robots: { index: false, follow: false } };

export default function EventsScreen() {
  return (
    <>
      <SheetHeight size="full" />
      <Suspense fallback={<p className="text-sm text-muted">Loading…</p>}>
        <YourEvents />
      </Suspense>
    </>
  );
}
