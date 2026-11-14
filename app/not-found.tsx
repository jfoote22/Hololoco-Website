// The panel's own back link leads to the map from here.
export default function NotFound() {
  return (
    <div className="flex flex-col gap-1">
      <h1 className="text-[22px] font-bold">Nothing here</h1>
      <p className="text-sm text-muted">This page doesn&apos;t exist, or the drop was removed.</p>
    </div>
  );
}
