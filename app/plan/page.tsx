import type { Metadata } from "next";
import { Suspense } from "react";
import { SheetHeight } from "@/components/map/SheetHeight";
import { YourPlan } from "@/components/plan/YourPlan";

export const metadata: Metadata = { title: "Your plan", robots: { index: false, follow: false } };

export default function PlanScreen() {
  return (
    <>
      <SheetHeight size="full" />
      <Suspense fallback={<p className="text-sm text-muted">Loading…</p>}>
        <YourPlan />
      </Suspense>
    </>
  );
}
