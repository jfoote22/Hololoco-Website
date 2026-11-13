// Where uploaded photos and models live. Approved files are public in the
// drop-assets bucket; everything else stays in the private uploads bucket and
// is only reachable by its owner and staff, through short-lived signed links.

import { supabaseUrl } from "@/lib/supabase/config";
import { browserClient } from "@/lib/supabase/browser";

export const UPLOADS_BUCKET = "uploads";
export const PUBLIC_BUCKET = "drop-assets";

export function publicAssetUrl(path: string | null | undefined): string | null {
  if (!path || !supabaseUrl) return null;
  return `${supabaseUrl}/storage/v1/object/public/${PUBLIC_BUCKET}/${path}`;
}

/** Signed links to private uploads, keyed by path. Paths the caller can't read are left out. */
export async function signedUploadUrls(paths: (string | null | undefined)[]): Promise<Record<string, string>> {
  const client = browserClient();
  const wanted = [...new Set(paths.filter((p): p is string => Boolean(p)))];
  if (!client || wanted.length === 0) return {};
  const { data } = await client.storage.from(UPLOADS_BUCKET).createSignedUrls(wanted, 60 * 60);
  const out: Record<string, string> = {};
  for (const item of data ?? []) if (item.path && item.signedUrl) out[item.path] = item.signedUrl;
  return out;
}

type WithUpload = {
  look: { kind: string; status?: string; thumbnail?: string | null };
  assetFiles: { model: string; thumbnail: string; photo: string | null } | null;
  preview?: { model?: string; thumbnail?: string; photo?: string };
};

/**
 * Adds signed preview links to drops whose upload isn't public yet, so their
 * owner (or staff) can see them in lists and on the map.
 */
export async function attachPreviews<T extends WithUpload>(drops: T[]): Promise<T[]> {
  const needing = drops.filter(
    (d) => d.look.kind === "upload" && d.assetFiles && (d.look.status !== "approved" || !d.look.thumbnail),
  );
  if (needing.length === 0) return drops;
  const signed = await signedUploadUrls(
    needing.flatMap((d) => [d.assetFiles?.model, d.assetFiles?.thumbnail, d.assetFiles?.photo]),
  );
  return drops.map((d) => {
    if (!needing.includes(d) || !d.assetFiles) return d;
    return {
      ...d,
      preview: {
        model: signed[d.assetFiles.model],
        thumbnail: signed[d.assetFiles.thumbnail],
        photo: d.assetFiles.photo ? signed[d.assetFiles.photo] : undefined,
      },
    };
  });
}
