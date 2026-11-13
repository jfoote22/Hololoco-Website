import type { Metadata } from "next";
import { ComingSoon } from "@/components/ComingSoon";

export const metadata: Metadata = { title: "Your drops" };

export default function YourDropsScreen() {
  return <ComingSoon title="Your drops" purpose="Edit, pause or delete what you posted, and see what's in review." phase="Phase 2" />;
}
