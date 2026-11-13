"use client";

import { useEffect, useState } from "react";
import { signedUploadUrls } from "@/lib/assets";
import { findUpload } from "@/lib/upload/store";
import type { DraftUpload } from "./draft";

export type UploadPreview = { model: string; thumbnail: string };

/**
 * Addresses to show a draft's photo or model: local blobs while it waits in this
 * browser, or short-lived signed links once uploaded (when editing).
 */
export function useUploadPreview(upload: DraftUpload | null): UploadPreview | null {
  const localId = upload?.localId ?? null;
  const modelPath = upload?.files?.model ?? null;
  const thumbnailPath = upload?.files?.thumbnail ?? null;
  const key = localId ?? modelPath ?? "";
  const [state, setState] = useState<(UploadPreview & { key: string }) | null>(null);

  useEffect(() => {
    if (!key) return;
    let cancelled = false;
    const made: string[] = [];
    (async () => {
      if (localId) {
        const kept = await findUpload(localId);
        if (!kept || cancelled) return;
        const model = URL.createObjectURL(kept.glb);
        const thumbnail = URL.createObjectURL(kept.thumbnail);
        made.push(model, thumbnail);
        setState({ key, model, thumbnail });
      } else if (modelPath && thumbnailPath) {
        const signed = await signedUploadUrls([modelPath, thumbnailPath]);
        if (cancelled || !signed[modelPath] || !signed[thumbnailPath]) return;
        setState({ key, model: signed[modelPath], thumbnail: signed[thumbnailPath] });
      }
    })();
    return () => {
      cancelled = true;
      for (const url of made) URL.revokeObjectURL(url);
    };
  }, [key, localId, modelPath, thumbnailPath]);

  return state && state.key === key ? state : null;
}
