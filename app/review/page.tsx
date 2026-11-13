import type { Metadata } from "next";
import { ComingSoon } from "@/components/ComingSoon";

export const metadata: Metadata = { title: "Review", robots: { index: false } };

export default function ReviewScreen() {
  return <ComingSoon title="Review" purpose="The moderator queue and reports. Staff only." phase="Phase 3" />;
}
