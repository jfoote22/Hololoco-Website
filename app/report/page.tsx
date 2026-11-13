import type { Metadata } from "next";
import { ComingSoon } from "@/components/ComingSoon";

export const metadata: Metadata = { title: "Report" };

export default function ReportScreen() {
  return (
    <ComingSoon
      title="Report"
      purpose="Report a drop, or ask for something to be removed from your property. No account needed."
      phase="Phase 3"
    />
  );
}
