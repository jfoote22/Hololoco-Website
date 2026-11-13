// The database returns drops as JSON (drop_to_json in the first migration).
// These turn that into the shapes the app uses.

import type { Audience, MyDrop, Owner, Placement, PublicDrop, Review, Timing } from "./types";

export type DropJson = {
  id: string;
  type: "object" | "message";
  title: string;
  description: string;
  objectId: string;
  placement: Placement;
  timeZone: string;
  timing: Timing;
  audience: Audience;
  owner: Owner;
  review: Review;
  paused: boolean;
  openNow: boolean;
  createdAt: string;
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
    look: { kind: "library", objectId: j.objectId },
    placement: j.placement,
    timeZone: j.timeZone,
    timing: j.timing,
    audience: j.audience,
    status,
    owner: j.owner,
  };
}

export function myDropFromJson(j: DropJson): MyDrop {
  return { ...dropFromJson(j), review: j.review, paused: j.paused, openNow: j.openNow, createdAt: j.createdAt };
}
