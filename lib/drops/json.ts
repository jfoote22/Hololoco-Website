// The database returns drops as JSON (drop_to_json in the first migration).
// These turn that into the shapes the app uses.

import type { AssetFiles, Audience, Look, MyDrop, Owner, Placement, PublicDrop, Review, Timing } from "./types";

type AssetJson = {
  id: string;
  kind: "photo" | "model";
  status: "pending" | "approved" | "rejected";
  model: string | null;
  thumbnail: string | null;
  photo: string | null;
};

export type DropJson = {
  id: string;
  type: "object" | "message";
  title: string;
  description: string;
  objectId: string | null;
  asset: AssetJson | null;
  placement: Placement;
  timeZone: string;
  timing: Timing;
  audience: Audience;
  owner: Owner;
  review: Review;
  /** Why staff didn't approve it; only on rejected drops. */
  reviewReason?: string | null;
  paused: boolean;
  openNow: boolean;
  createdAt: string;
  /** Only from my_drops: hidden while staff check a report about it. */
  hiddenForReport?: boolean;
  /** Only from my_drops and the review queue: the upload's private files. */
  assetFiles?: AssetFiles | null;
};

export function dropFromJson(j: DropJson): PublicDrop {
  const status = j.review === "rejected" ? "rejected" : j.review === "pending" ? "in_review" : j.paused ? "paused" : "live";
  return {
    id: j.id,
    type: j.type,
    // Owner ids stay in the database; the public only sees the owner's name.
    ownerId: "",
    title: j.title,
    description: j.description,
    look: lookFromJson(j),
    placement: j.placement,
    timeZone: j.timeZone,
    timing: j.timing,
    audience: j.audience,
    status,
    owner: j.owner,
  };
}

export function myDropFromJson(j: DropJson): MyDrop {
  return {
    ...dropFromJson(j),
    review: j.review,
    reviewReason: j.reviewReason ?? null,
    paused: j.paused,
    openNow: j.openNow,
    createdAt: j.createdAt,
    hiddenForReport: j.hiddenForReport === true,
    assetFiles: j.assetFiles ?? null,
  };
}

function lookFromJson(j: DropJson): Look {
  if (j.asset) {
    return {
      kind: "upload",
      assetId: j.asset.id,
      assetKind: j.asset.kind,
      status: j.asset.status,
      model: j.asset.model,
      thumbnail: j.asset.thumbnail,
      photo: j.asset.photo,
    };
  }
  return { kind: "library", objectId: j.objectId ?? "gift" };
}
