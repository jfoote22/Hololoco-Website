// Stand-in for the 3D map until Phase 1 connects Mapbox through lib/map/engine.ts.
// It draws a quiet street grid so the panel has something real-looking to float over.
export function MapView() {
  return (
    <section aria-label="Map" className="fixed inset-0 bg-map">
      <svg className="absolute inset-0 h-full w-full" aria-hidden="true">
        <defs>
          <pattern id="blocks" width="120" height="96" patternUnits="userSpaceOnUse" patternTransform="rotate(-12)">
            <rect width="120" height="96" fill="var(--color-map)" />
            <rect x="10" y="10" width="46" height="34" rx="3" fill="#d9e0e5" />
            <rect x="64" y="10" width="46" height="34" rx="3" fill="#dce3e8" />
            <rect x="10" y="52" width="100" height="34" rx="3" fill="#d6dee3" />
          </pattern>
        </defs>
        <rect width="100%" height="100%" fill="url(#blocks)" />
      </svg>
      <p className="absolute right-4 bottom-4 max-w-[min(320px,calc(100%-32px))] rounded-lg bg-surface/95 px-3 py-2 text-[13px] text-muted shadow-sm max-md:top-4 max-md:bottom-auto">
        The 3D map arrives in Phase 1. This is a placeholder.
      </p>
    </section>
  );
}
