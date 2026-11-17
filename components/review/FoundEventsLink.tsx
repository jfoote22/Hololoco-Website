"use client";

// For staff on Your drops: the way in to the found events, with how many are waiting.

import Link from "next/link";
import { useEffect, useState } from "react";
import { waitingCount } from "@/lib/found";

export function FoundEventsLink() {
  const [count, setCount] = useState<number | null>(null);
  useEffect(() => {
    let cancelled = false;
    waitingCount().then((n) => !cancelled && setCount(n));
    return () => {
      cancelled = true;
    };
  }, []);
  return (
    <Link
      href="/review/found"
      className="flex min-h-14 items-center justify-between gap-3 rounded-xl border border-line px-4 py-3 hover:bg-wash"
    >
      <span className="flex flex-col">
        <span className="font-semibold">Found events</span>
        <span className="text-sm text-muted">
          {count === null ? "Events and giveaways around Austin" : count === 1 ? "1 waiting for you to review" : `${count} waiting for you to review`}
        </span>
      </span>
      <span aria-hidden="true" className="text-xl text-accent">
        ›
      </span>
    </Link>
  );
}
