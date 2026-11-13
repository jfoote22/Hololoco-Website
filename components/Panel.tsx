import Link from "next/link";

// Desktop: a panel floating on the left, about 380 px wide.
// Phone: a bottom sheet. Peek, half and full heights with dragging come in Phase 1;
// for now it sits at half height and scrolls.
export function Panel({ children }: { children: React.ReactNode }) {
  return (
    <aside
      aria-label="Panel"
      className="fixed inset-x-0 bottom-0 z-10 flex max-h-[55dvh] flex-col rounded-t-(--radius-panel) bg-surface shadow-(--shadow-panel) md:inset-x-auto md:top-4 md:bottom-4 md:left-4 md:max-h-none md:w-[380px] md:rounded-(--radius-panel)"
    >
      <div className="mx-auto mt-2 h-1 w-10 rounded-full bg-line md:hidden" aria-hidden="true" />
      <header className="flex items-center justify-between px-4 pt-3 pb-1 md:pt-4">
        <Link href="/" className="flex min-h-11 items-center gap-2 font-display text-xl font-bold tracking-tight">
          <Logo />
          hololoco
        </Link>
        <Link href="/mine" className="flex min-h-11 items-center px-2 text-sm font-medium text-muted hover:text-ink">
          Your drops
        </Link>
      </header>
      <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-4 pt-2 pb-4">{children}</div>
    </aside>
  );
}

function Logo() {
  return (
    <svg width="22" height="30" viewBox="0 0 22 30" aria-hidden="true">
      <circle cx="11" cy="11" r="8.5" fill="none" stroke="var(--color-accent)" strokeWidth="4" />
      <rect x="10" y="20" width="2" height="9" fill="var(--color-accent)" />
    </svg>
  );
}
