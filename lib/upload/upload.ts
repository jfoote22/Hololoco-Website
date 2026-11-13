// Uploads a processed photo or model to the person's own folder in the private
// uploads bucket, then records it. Storage checks the folder, size and file type;
// the database checks the files are really there and the daily limit.

import { UPLOADS_BUCKET } from "@/lib/assets";
import { browserClient } from "@/lib/supabase/browser";
import { uploadLimits } from "./limits";
import type { ProcessedUpload } from "./types";

function errorText(message: string): string {
  if (message.includes("limit_uploads")) return `You can upload ${uploadLimits.perDay} photos or models a day. Try again tomorrow.`;
  if (message.includes("upload_missing")) return "The upload didn't finish. Try publishing again.";
  if (/exceeded the maximum allowed size|too large|413/i.test(message)) return "That file is too big to upload.";
  if (/mime type|not supported/i.test(message)) return "That kind of file can't be uploaded.";
  if (/row-level security|Unauthorized|403/i.test(message)) return "Your sign-in has expired. Sign in again.";
  if (/Failed to fetch|NetworkError/i.test(message)) return "Couldn't reach Hololoco. Check your connection and try again.";
  return "Couldn't upload it. Try again in a moment.";
}

export async function uploadAsset(userId: string, upload: ProcessedUpload): Promise<{ assetId: string } | { error: string }> {
  const client = browserClient();
  if (!client) return { error: "Uploading isn't switched on here yet." };

  const assetId = crypto.randomUUID();
  const base = `${userId}/${assetId}`;
  const files: [string, Blob, string][] = [
    [`${base}/model.glb`, upload.glb, "model/gltf-binary"],
    [`${base}/thumbnail.png`, upload.thumbnail, "image/png"],
  ];
  if (upload.photo) files.push([`${base}/photo.jpg`, upload.photo, "image/jpeg"]);

  const bucket = client.storage.from(UPLOADS_BUCKET);
  for (const [path, blob, contentType] of files) {
    const { error } = await bucket.upload(path, blob, { contentType, upsert: false, cacheControl: "3600" });
    if (error) {
      await bucket.remove(files.map(([p]) => p));
      return { error: errorText(error.message) };
    }
  }

  const { error } = await client.from("assets").insert({
    id: assetId,
    kind: upload.kind,
    source_name: upload.sourceName.slice(0, 200),
    source_format: upload.sourceFormat,
    triangles: upload.triangles,
    model_path: files[0][0],
    thumbnail_path: files[1][0],
    photo_path: upload.photo ? files[2][0] : null,
  });
  if (error) {
    await bucket.remove(files.map(([p]) => p));
    return { error: errorText(error.message) };
  }
  return { assetId };
}
