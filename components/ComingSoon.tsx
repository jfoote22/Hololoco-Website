import Link from "next/link";

// Placeholder for a screen from the design doc that later phases build.
export function ComingSoon({
  title,
  purpose,
  phase,
  children,
}: {
  title: string;
  purpose: string;
  phase: string;
  children?: React.ReactNode;
}) {
  return (
    <>
      <div className="flex flex-col gap-1">
        <h1 className="text-[22px] font-bold">{title}</h1>
        <p className="text-sm text-muted">{purpose}</p>
      </div>
      {children}
      <p className="rounded-lg bg-wash px-3 py-2 text-[13px] text-muted">Coming in {phase}.</p>
      <Link href="/" className="flex min-h-11 items-center text-sm font-medium text-accent hover:underline">
        Back to the map
      </Link>
    </>
  );
}
