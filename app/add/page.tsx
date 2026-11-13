import type { Metadata } from "next";
import { Suspense } from "react";
import { AddFlowRoute } from "@/components/add/AddFlow";

export const metadata: Metadata = { title: "Add to the map" };

// The flow runs in the browser: it keeps its draft there and reads ?edit=<id>.
export default function AddScreen() {
  return (
    <Suspense fallback={<p className="text-sm text-muted">Loading…</p>}>
      <AddFlowRoute />
    </Suspense>
  );
}
