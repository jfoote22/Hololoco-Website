import type { NextRequest } from "next/server";
import { scaledGlb } from "@/lib/ar/glb";
import { modelFor } from "@/lib/drops/format";
import { getDrop } from "@/lib/drops/page";

// A drop's model at its true size, for phones' own AR viewers. The map's models
// are 1 m across and scaled by the drop's size; AR viewers show a file as it is.
// Android's Scene Viewer reads it from here, and iPhones turn it into USDZ in the
// browser first. Only drops the public can see, like the drop's page.
export async function GET(request: NextRequest, ctx: RouteContext<"/d/[id]/model.glb">) {
  const { id } = await ctx.params;
  const drop = await getDrop(id);
  const source = drop ? modelFor(drop) : null;
  if (!drop || !source) return new Response("Not found", { status: 404 });

  // Ready-made objects are this site's own files; uploads are in public storage.
  const upstream = await fetch(new URL(source, request.url));
  if (!upstream.ok || !upstream.body) return new Response("The model isn't available right now.", { status: 502 });
  try {
    return new Response(await scaledGlb(upstream.body, drop.placement.size), {
      headers: { "Content-Type": "model/gltf-binary", "Cache-Control": "public, max-age=300" },
    });
  } catch (error) {
    console.warn(`Couldn't prepare drop ${id}'s model for AR:`, error);
    return new Response("The model couldn't be prepared.", { status: 502 });
  }
}
