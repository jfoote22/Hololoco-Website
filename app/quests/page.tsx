import type { Metadata } from "next";
import { Suspense } from "react";
import { SheetHeight } from "@/components/map/SheetHeight";
import { QuestList } from "@/components/quests/QuestList";

export const metadata: Metadata = { title: "Quests", robots: { index: false, follow: false } };

// Staff only. The page runs in the browser with the person's session, and the
// database refuses the staff calls from anyone who isn't staff.
export default function QuestsScreen() {
  return (
    <>
      <SheetHeight size="full" />
      <Suspense fallback={<p className="text-sm text-muted">Loading…</p>}>
        <QuestList />
      </Suspense>
    </>
  );
}
