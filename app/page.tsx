import { Suspense } from "react";
import { YourDrops } from "@/components/mine/YourDrops";

// The start page: what the website is for and sign-in, or, once signed in, Your
// drops. It runs in the browser: the session lives there, and the database
// decides what each person can see.
export default function StartScreen() {
  return (
    <Suspense fallback={<p className="text-sm text-muted">Loading…</p>}>
      <YourDrops />
    </Suspense>
  );
}
