import type { Metadata } from "next";
import { ComingSoon } from "@/components/ComingSoon";

export const metadata: Metadata = { title: "Terms and privacy" };

export default function LegalScreen() {
  return (
    <ComingSoon
      title="Terms and privacy"
      purpose="Terms of use, privacy policy and content rules. A lawyer reviews them before the map opens to the public."
      phase="Phase 3"
    />
  );
}
