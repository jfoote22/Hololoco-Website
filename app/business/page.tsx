import type { Metadata } from "next";
import { ComingSoon } from "@/components/ComingSoon";

export const metadata: Metadata = { title: "Business" };

export default function BusinessScreen() {
  return <ComingSoon title="Business" purpose="Your business details, and verification so you can post offers." phase="Phase 4" />;
}
