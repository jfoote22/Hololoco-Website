import type { Metadata } from "next";
import { Suspense } from "react";
import { PanelWidth } from "@/components/map/PanelWidth";
import { SheetHeight } from "@/components/map/SheetHeight";
import { FoundReviewScreen } from "@/components/review/FoundReview";

export const metadata: Metadata = { title: "Found events", robots: { index: false, follow: false } };

// Staff only. The page runs in the browser with the person's session, and the
// database refuses every call from anyone who isn't staff. On a computer the list
// takes the left half of the screen and the map the right.
export default function FoundEventsScreen() {
  return (
    <>
      <SheetHeight size="half" />
      <PanelWidth width="wide" />
      <Suspense fallback={<p className="text-sm text-muted">Loading…</p>}>
        <FoundReviewScreen />
      </Suspense>
    </>
  );
}
