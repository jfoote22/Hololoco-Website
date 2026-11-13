import { Suspense } from "react";
import { ComingSoon } from "@/components/ComingSoon";

// The shareable page for one drop. Under Cache Components, params are read inside
// Suspense so the rest of the screen still prerenders as a static shell.
export default function DropScreen({ params }: PageProps<"/d/[id]">) {
  return (
    <ComingSoon title="Drop" purpose="The shareable page for one drop, with a link preview." phase="Phase 1">
      <Suspense fallback={<p className="text-sm text-muted">Loading…</p>}>
        <DropId params={params} />
      </Suspense>
    </ComingSoon>
  );
}

async function DropId({ params }: { params: PageProps<"/d/[id]">["params"] }) {
  const { id } = await params;
  return <p className="text-sm text-muted">Drop {id}</p>;
}
