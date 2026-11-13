import type { Metadata } from "next";
import { Suspense } from "react";
import { SheetHeight } from "@/components/map/SheetHeight";
import { ReviewQueue } from "@/components/review/ReviewQueue";

export const metadata: Metadata = { title: "Review", robots: { index: false, follow: false } };

// Staff only. The page runs in the browser with the person's session, and the
// database refuses every review call from anyone who isn't staff.
export default function ReviewScreen() {
  return (
    <>
      <SheetHeight size="full" />
      <Suspense fallback={<p className="text-sm text-muted">Loading…</p>}>
        <ReviewQueue />
      </Suspense>
    </>
  );
}
