import Link from "next/link";
import { TypeFilter } from "@/components/TypeFilter";

export default function MapScreen() {
  return (
    <>
      <div className="flex flex-col gap-1">
        <h1 className="text-[22px] font-bold">Add something to the map</h1>
        <p className="text-sm text-muted">Place an object, an offer or a message at a real place, for anyone to find.</p>
      </div>

      <Link
        href="/add"
        className="flex min-h-11 items-center justify-center rounded-[9px] bg-accent px-4 font-bold text-white hover:bg-accent-strong"
      >
        Add to the map
      </Link>

      <form role="search" action="/" className="flex flex-col gap-3">
        <label htmlFor="q" className="sr-only">
          Search places
        </label>
        <input
          id="q"
          name="q"
          type="search"
          placeholder="Search places"
          className="min-h-11 w-full rounded-lg border border-[#c3ced4] bg-surface px-3"
        />
        <TypeFilter />
      </form>

      <div className="rounded-(--radius-panel) border border-dashed border-line px-4 py-6 text-center text-sm text-muted">
        Nothing nearby yet. Drops show up here once the map is connected.
      </div>
    </>
  );
}
