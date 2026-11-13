import Link from "next/link";
import { SheetHeight } from "@/components/map/SheetHeight";
import { NearbyList } from "@/components/NearbyList";
import { SearchBox } from "@/components/SearchBox";
import { TypeFilter } from "@/components/TypeFilter";

export default function MapScreen() {
  return (
    <>
      <h1 className="sr-only">Hololoco map</h1>
      <SheetHeight size="peek" />

      {/* On phones, search and the filter float at the top of the map instead of sitting in the sheet. */}
      <div className="flex flex-col gap-2 md:gap-3 max-md:fixed max-md:inset-x-3 max-md:top-3">
        <SearchBox />
        <TypeFilter />
      </div>

      <Link
        href="/add"
        className="flex min-h-12 shrink-0 items-center justify-center gap-2 rounded-[10px] bg-accent px-4 font-semibold text-white hover:bg-accent-strong"
      >
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden="true">
          <path d="M12 5v14M5 12h14" />
        </svg>
        Add to the map
      </Link>

      <NearbyList />
    </>
  );
}
