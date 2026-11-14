"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useSession } from "@/components/auth/session";

// Every screen but the start page gets a way back to it: a link at the top of the
// panel on wider screens, and a button over the map's top-left corner on phones.
export function BackToMap() {
  const signedIn = useSession().status === "signed-in";
  if (usePathname() === "/") return null;
  return (
    <Link
      href="/"
      className="-ml-1.5 flex min-h-11 shrink-0 items-center gap-1 self-start text-sm font-semibold text-accent hover:underline max-md:fixed max-md:top-3 max-md:left-3 max-md:ml-0 max-md:size-11 max-md:justify-center max-md:rounded-[10px] max-md:bg-surface max-md:text-ink max-md:shadow-[0_2px_8px_rgb(23_36_44/0.18)]"
    >
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <path d="M15 5l-7 7 7 7" />
      </svg>
      <span className="max-md:sr-only">{signedIn ? "Back to your drops" : "Back"}</span>
    </Link>
  );
}
