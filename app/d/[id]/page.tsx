import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { Suspense } from "react";
import { DropThumb } from "@/components/DropThumb";
import { FocusDrop } from "@/components/map/FocusDrop";
import { SheetHeight } from "@/components/map/SheetHeight";
import { ShareButton } from "@/components/ShareButton";
import { bylineLong, remainingText, savingsText, timingText } from "@/lib/drops/format";
import { getDrop, prerenderedDropIds } from "@/lib/drops/page";

// The shareable page for one drop. Known drops are prerendered; the map flies to the
// drop and highlights its pin while this page is open.

export async function generateStaticParams() {
  return prerenderedDropIds().map((id) => ({ id }));
}

export async function generateMetadata({ params }: PageProps<"/d/[id]">): Promise<Metadata> {
  const drop = await getDrop((await params).id);
  if (!drop) return { title: "Drop not found" };
  const description = `${bylineLong(drop)}. ${drop.description}`;
  return {
    title: drop.title,
    description,
    openGraph: { title: drop.title, description, siteName: "Hololoco", type: "website" },
    twitter: { card: "summary_large_image", title: drop.title, description },
    // Link-only drops are for the people given the link, so search engines leave them out.
    robots: drop.audience === "link" ? { index: false, follow: false } : undefined,
  };
}

// The back link and a placeholder show at once on navigation; the drop streams in.
export default function DropScreen({ params }: PageProps<"/d/[id]">) {
  return (
    <>
      <SheetHeight size="half" />
      <Link
        href="/"
        className="-ml-1.5 flex min-h-11 items-center gap-1 self-start text-sm font-semibold text-accent hover:underline max-md:fixed max-md:top-3 max-md:left-3 max-md:ml-0 max-md:size-11 max-md:justify-center max-md:rounded-[10px] max-md:bg-surface max-md:text-ink max-md:shadow-[0_2px_8px_rgb(23_36_44/0.18)]"
      >
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
          <path d="M15 5l-7 7 7 7" />
        </svg>
        <span className="max-md:sr-only">Back to the map</span>
      </Link>
      <Suspense fallback={<DropPlaceholder />}>
        <DropDetails params={params} />
      </Suspense>
    </>
  );
}

function DropPlaceholder() {
  return (
    <div className="flex flex-col gap-4 motion-safe:animate-pulse" aria-label="Loading the drop">
      <div className="h-[76px] w-[76px] rounded-(--radius-panel) bg-wash md:h-40 md:w-full" />
      <div className="h-4 w-1/2 rounded bg-wash" />
      <div className="h-7 w-4/5 rounded bg-wash" />
      <div className="h-4 w-full rounded bg-wash" />
    </div>
  );
}

async function DropDetails({ params }: { params: PageProps<"/d/[id]">["params"] }) {
  const { id } = await params;
  const drop = await getDrop(id);
  if (!drop) notFound();

  const when = timingText(drop.timing);

  return (
    <>
      <FocusDrop drop={drop} />

      <article className="flex flex-col gap-4">
        <div className="flex items-center gap-3.5 md:flex-col md:items-stretch md:gap-4">
          <DropThumb
            drop={drop}
            eager
            className="size-[76px] rounded-(--radius-panel) md:h-40 md:w-full"
            imageClassName="size-[62px] md:size-[120px]"
          />
          <div className="flex flex-col gap-1">
            <p className="text-[13px] text-muted">{bylineLong(drop)}</p>
            <h1 className="text-[22px] leading-tight font-semibold md:text-[26px]">{drop.title}</h1>
          </div>
        </div>

        <p className="leading-normal">{drop.description}</p>

        <ul className="flex flex-col gap-2.5 text-sm">
          {drop.offer && <Fact icon="tag">{savingsText(drop.offer)}</Fact>}
          {when && <Fact icon="clock">{when}</Fact>}
          {drop.offer && <Fact icon="pin">{remainingText(drop.offer)}</Fact>}
          {drop.audience === "link" && <Fact icon="link">Shared by link only. It isn&apos;t shown on the public map.</Fact>}
        </ul>

        {drop.offer && <p className="text-[13px] text-muted">{drop.offer.terms}</p>}
        {drop.sample && <p className="text-[13px] text-muted">This is a sample drop for testing.</p>}
      </article>

      <div className="sticky -bottom-4 -mx-4 -mb-4 mt-auto flex flex-col gap-2 border-t border-line bg-surface px-4 pt-3 pb-4 max-md:pb-2">
        {drop.offer && (
          <p className="rounded-lg bg-wash px-3 py-2 text-[13px] text-muted">
            Claiming a code comes in Phase 4, with sign-in.
          </p>
        )}
        <div className="flex items-center justify-between">
          <ShareButton title={drop.title} path={`/d/${drop.id}`} />
          <Link
            href={`/report?drop=${drop.id}`}
            className="flex min-h-11 items-center gap-1.5 px-2 text-sm font-medium text-muted hover:text-ink"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
              <path d="M6 21V4M6 4h11l-2 4 2 4H6" />
            </svg>
            Report
          </Link>
        </div>
      </div>
    </>
  );
}

const icons = {
  tag: (
    <>
      <path d="M4 12V5a1 1 0 011-1h7l8 8-8 8z" />
      <circle cx="8.5" cy="8.5" r="1.2" />
    </>
  ),
  clock: (
    <>
      <circle cx="12" cy="12" r="8" />
      <path d="M12 8v4l3 2" />
    </>
  ),
  pin: (
    <>
      <path d="M12 21s7-6.2 7-11.5A7 7 0 005 9.5C5 14.8 12 21 12 21z" />
      <circle cx="12" cy="9.5" r="2.5" />
    </>
  ),
  link: <path d="M10 14a4 4 0 005.7 0l3-3a4 4 0 00-5.7-5.7l-1 1M14 10a4 4 0 00-5.7 0l-3 3a4 4 0 005.7 5.7l1-1" />,
};

function Fact({ icon, children }: { icon: keyof typeof icons; children: React.ReactNode }) {
  return (
    <li className="flex items-start gap-2.5">
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="var(--color-muted)" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className="mt-px shrink-0">
        {icons[icon]}
      </svg>
      <span>{children}</span>
    </li>
  );
}
