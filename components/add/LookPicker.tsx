"use client";

// How a drop looks: a ready-made object, a photo (shown in a frame), or the
// person's own 3D model (GLB or FBX). Photos and models are processed right here
// in the browser and only uploaded at Publish.

import Image from "next/image";
import { useState } from "react";
import { secondaryButton } from "@/components/ui";
import { library } from "@/lib/library/objects";
import { uploadLimits } from "@/lib/upload/limits";
import { forgetUpload, keepUpload } from "@/lib/upload/store";
import { UploadError } from "@/lib/upload/types";
import type { Draft } from "./draft";
import type { UploadPreview } from "./useUploadPreview";

type Tab = "library" | "photo" | "model";

const TABS: { id: Tab; label: string }[] = [
  { id: "library", label: "Ready-made" },
  { id: "photo", label: "Photo" },
  { id: "model", label: "3D model" },
];

const MODEL_ACCEPT = ".glb,.fbx,.png,.jpg,.jpeg,.tga,.bmp,.webp,model/gltf-binary,image/png,image/jpeg,image/webp";
const PHOTO_ACCEPT = "image/jpeg,image/png,image/webp,image/heic,image/heif,.heic,.heif";

const fmt = (n: number) => n.toLocaleString("en-US");

export function LookPicker({
  draft,
  update,
  preview,
}: {
  draft: Draft;
  update: (change: Partial<Draft>) => void;
  preview: UploadPreview | null;
}) {
  // Kept in the draft so Next can tell a chosen photo or model apart from one that isn't ready.
  const tab = draft.look;
  const setTab = (look: Tab) => update({ look });
  const [working, setWorking] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  function pickLibrary(objectId: string) {
    if (draft.upload?.localId) void forgetUpload(draft.upload.localId);
    update({ objectId, upload: null });
  }

  async function choose(list: FileList | null, kind: "photo" | "model") {
    // Copy now: the input is cleared right after this is called, which empties its FileList.
    const files = list ? [...list] : [];
    if (files.length === 0) return;
    setError(null);
    const report = (message: string) => {
      if (process.env.NODE_ENV === "development") console.info(`[upload] ${message}`);
      setWorking(message);
    };
    report(kind === "photo" ? "Reading the photo…" : "Reading the model…");
    try {
      const processed =
        kind === "photo"
          ? await (await import("@/lib/upload/photo")).processPhoto(files[0], report)
          : await (await import("@/lib/upload/model")).processModel(files, report);
      report("Keeping it on this device until you publish…");
      const localId = crypto.randomUUID();
      await keepUpload(localId, processed);
      if (draft.upload?.localId) void forgetUpload(draft.upload.localId);
      update({
        upload: {
          kind,
          localId,
          assetId: null,
          files: null,
          name: processed.sourceName,
          triangles: processed.triangles,
          originalTriangles: processed.originalTriangles,
          notes: processed.notes,
        },
      });
    } catch (problem) {
      console.warn("Couldn't process the file:", problem, (problem as Error)?.stack);
      setError(
        problem instanceof UploadError ? problem.message : "Something went wrong reading that file. Try another one.",
      );
    } finally {
      setWorking(null);
    }
  }

  const upload = draft.upload && draft.upload.kind === tab ? draft.upload : null;

  return (
    // min-w-0: a fieldset otherwise grows to fit a long file name instead of truncating it.
    <fieldset className="flex min-w-0 flex-col gap-3">
      <legend className="mb-2 text-sm font-semibold">How it looks</legend>

      <div role="group" aria-label="Kind of look" className="grid grid-cols-3 gap-1 rounded-[10px] bg-wash p-1">
        {TABS.map((t) => (
          <button
            key={t.id}
            type="button"
            aria-pressed={tab === t.id}
            onClick={() => setTab(t.id)}
            className="min-h-10 rounded-lg text-sm font-semibold text-muted aria-pressed:bg-surface aria-pressed:text-ink aria-pressed:shadow-sm"
          >
            {t.label}
          </button>
        ))}
      </div>

      {tab === "library" && (
        <div className="grid grid-cols-3 gap-2">
          {library.map((object) => (
            <label
              key={object.id}
              className="flex cursor-pointer flex-col items-center gap-1 rounded-lg border border-line p-2 text-center text-xs has-checked:border-accent has-checked:bg-accent-wash has-focus-visible:outline-2 has-focus-visible:outline-accent"
            >
              <input
                type="radio"
                name="look"
                checked={!draft.upload && draft.objectId === object.id}
                onChange={() => pickLibrary(object.id)}
                className="sr-only"
              />
              <Image src={object.thumbnail} alt="" width={128} height={128} className="size-14 object-contain" />
              {object.name}
            </label>
          ))}
        </div>
      )}

      {tab !== "library" && (
        <div className="flex flex-col gap-3">
          {upload && (
            <div className="flex items-center gap-3 rounded-lg border border-accent bg-accent-wash p-3">
              <span className="flex size-16 shrink-0 items-center justify-center rounded-lg bg-surface">
                {preview && (
                  // A local or signed address that next/image can't optimise.
                  // eslint-disable-next-line @next/next/no-img-element
                  <img src={preview.thumbnail} alt="" className="size-14 object-contain" />
                )}
              </span>
              <span className="flex min-w-0 flex-col text-sm">
                <b className="truncate">{upload.name}</b>
                <span className="text-muted">
                  {upload.kind === "photo"
                    ? "In a frame, standing on the ground"
                    : upload.originalTriangles > upload.triangles
                      ? `Simplified from ${fmt(upload.originalTriangles)} to ${fmt(upload.triangles)} triangles`
                      : `${fmt(upload.triangles)} triangles`}
                </span>
              </span>
            </div>
          )}
          {upload?.notes.map((note) => (
            <p key={note} className="text-[13px] text-review">
              {note}
            </p>
          ))}

          {working ? (
            <p role="status" className="rounded-lg bg-wash px-3 py-2.5 text-sm">
              {working}
            </p>
          ) : (
            <label className={`${secondaryButton} cursor-pointer has-focus-visible:outline-2 has-focus-visible:outline-accent`}>
              <input
                type="file"
                accept={tab === "photo" ? PHOTO_ACCEPT : MODEL_ACCEPT}
                multiple={tab === "model"}
                onChange={(event) => {
                  void choose(event.target.files, tab);
                  event.target.value = "";
                }}
                className="sr-only"
              />
              {upload ? (tab === "photo" ? "Choose a different photo" : "Choose a different model") : tab === "photo" ? "Choose a photo" : "Choose a GLB or FBX file"}
            </label>
          )}

          <p className="text-xs text-muted">
            {tab === "photo"
              ? "JPEG, PNG or WebP. Its location and other details are removed before it leaves your device."
              : `GLB or FBX, up to ${fmt(uploadLimits.modelSourceTriangles)} triangles. If your FBX keeps its textures in separate image files, choose them at the same time. It's simplified to ${fmt(uploadLimits.modelTriangles)} triangles or fewer, since it's small on the map.`}
          </p>

          {error && (
            <p role="alert" className="text-sm text-rejected">
              {error}
            </p>
          )}
        </div>
      )}

      <p className="text-xs text-muted">A person checks every photo and model before it goes on the public map.</p>
    </fieldset>
  );
}
