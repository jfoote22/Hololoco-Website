import type { Metadata } from "next";
import { Suspense } from "react";
import { SheetHeight } from "@/components/map/SheetHeight";
import { ReportRoute } from "@/components/report/ReportForm";

export const metadata: Metadata = {
  title: "Report",
  description: "Report a drop, or ask for a drop to be removed from your property. No account needed.",
};

// The form reads ?drop=<id> and sends the report straight from the browser.
export default function ReportScreen() {
  return (
    <>
      <SheetHeight size="full" />
      <Suspense fallback={<p className="text-sm text-muted">Loading…</p>}>
        <ReportRoute />
      </Suspense>
    </>
  );
}
