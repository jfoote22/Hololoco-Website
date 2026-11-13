"use client";

import { useState } from "react";

/** Opens the phone's share sheet, or copies the link where there isn't one. */
export function ShareButton({ title, path }: { title: string; path: string }) {
  const [message, setMessage] = useState("");

  async function share() {
    const url = new URL(path, window.location.origin).href;
    if (navigator.share) {
      try {
        await navigator.share({ title, url });
      } catch {
        // Closing the share sheet isn't an error worth showing.
      }
      return;
    }
    try {
      await navigator.clipboard.writeText(url);
      setMessage("Link copied");
    } catch {
      setMessage(url);
    }
    setTimeout(() => setMessage(""), 3000);
  }

  return (
    <span className="flex items-center gap-2">
      <button
        type="button"
        onClick={share}
        className="flex min-h-11 items-center gap-1.5 px-2 text-sm font-medium text-muted hover:text-ink"
      >
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
          <path d="M12 15V4M8 8l4-4 4 4M5 13v6a1 1 0 001 1h12a1 1 0 001-1v-6" />
        </svg>
        Share
      </button>
      <span role="status" className="text-[13px] text-good">
        {message}
      </span>
    </span>
  );
}
