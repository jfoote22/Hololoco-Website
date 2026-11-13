import Link from "next/link";

export default function NotFound() {
  return (
    <>
      <div className="flex flex-col gap-1">
        <h1 className="text-[22px] font-bold">Nothing here</h1>
        <p className="text-sm text-muted">This page doesn&apos;t exist, or the drop was removed.</p>
      </div>
      <Link href="/" className="flex min-h-11 items-center text-sm font-medium text-accent hover:underline">
        Back to the map
      </Link>
    </>
  );
}
