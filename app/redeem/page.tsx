import type { Metadata } from "next";
import { Suspense } from "react";
import { SheetHeight } from "@/components/map/SheetHeight";
import { RedeemCode } from "@/components/redeem/RedeemCode";

export const metadata: Metadata = { title: "Redeem a code", robots: { index: false, follow: false } };

export default function RedeemScreen() {
  return (
    <>
      <SheetHeight size="full" />
      <Suspense fallback={<p className="text-sm text-muted">Loading…</p>}>
        <RedeemCode />
      </Suspense>
    </>
  );
}
