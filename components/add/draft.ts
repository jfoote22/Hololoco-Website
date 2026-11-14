// The add flow's draft. It's saved in this browser as it changes, so it survives
// signing in (including a sign-in link that reloads the page) and an accidental
// tap away. Only the person's own browser ever holds it until they publish.

import { limits } from "@/lib/drops/limits";
import type { Audience, DropInput, DropType, MyDrop, Placement, Rarity, Timing, WeeklyBlock } from "@/lib/drops/types";
import { library } from "@/lib/library/objects";

export type Step = 1 | 2 | 3;

/** A photo or model chosen for the drop instead of a ready-made object. */
export type DraftUpload = {
  kind: "photo" | "model";
  /** Processed and waiting in this browser (lib/upload/store) until Publish. */
  localId: string | null;
  /** Uploaded already: after Publish, or a drop being edited. */
  assetId: string | null;
  /** Private file paths of an uploaded one, to preview it. */
  files: { model: string; thumbnail: string } | null;
  name: string;
  triangles: number;
  originalTriangles: number;
  notes: string[];
};

/** An offer's details, kept even while another type is chosen so switching back loses nothing. */
export type DraftOffer = {
  savings: string;
  terms: string;
  quantity: number;
  perPerson: number;
  rarity: Rarity;
  inQuests: boolean;
};

export type Draft = {
  version: 1;
  /** The drop being edited, or null for a new one. */
  editing: string | null;
  step: Step;
  type: DropType;
  title: string;
  description: string;
  objectId: string;
  /** The kind of look chosen. A photo or model has to be ready before moving on. */
  look: "library" | "photo" | "model";
  /** Set when the drop uses a photo or model instead of objectId. */
  upload: DraftUpload | null;
  offer: DraftOffer;
  placement: Placement | null;
  timeZone: string;
  timing: Timing;
  audience: Audience;
};

const KEY = "hl-draft";

export const PLACEMENT_DEFAULTS = { height: 0, size: 4, turn: 0 };

/** Quests are opt-in: the business ticks the box. */
export const OFFER_DEFAULTS: DraftOffer = {
  savings: "",
  terms: "",
  quantity: 100,
  perPerson: 1,
  rarity: "common",
  inQuests: false,
};

export function browserTimeZone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
  } catch {
    return "UTC";
  }
}

export function newDraft(): Draft {
  return {
    version: 1,
    editing: null,
    step: 1,
    // The website is for businesses, so an offer comes first.
    type: "offer",
    title: "",
    description: "",
    objectId: library[0]?.id ?? "gift",
    look: "library",
    upload: null,
    offer: OFFER_DEFAULTS,
    placement: null,
    timeZone: browserTimeZone(),
    timing: { kind: "always" },
    audience: "everyone",
  };
}

export function loadDraft(): Draft | null {
  try {
    const raw = window.localStorage.getItem(KEY);
    if (!raw) return null;
    const draft = JSON.parse(raw) as Draft;
    if (draft?.version !== 1) return null;
    // Drafts saved before `look` or offers existed: go by what they hold.
    return {
      ...draft,
      upload: draft.upload ?? null,
      look: draft.look ?? draft.upload?.kind ?? "library",
      offer: { ...OFFER_DEFAULTS, ...draft.offer },
    };
  } catch {
    return null;
  }
}

export function storeDraft(draft: Draft) {
  try {
    window.localStorage.setItem(KEY, JSON.stringify(draft));
  } catch {
    // Private windows can refuse storage. The draft still works until the page closes.
  }
}

export function clearDraft() {
  try {
    window.localStorage.removeItem(KEY);
  } catch {
    // Nothing to clear.
  }
}

export function draftFromDrop(drop: MyDrop): Draft {
  return {
    version: 1,
    editing: drop.id,
    step: 1,
    type: drop.type,
    title: drop.title,
    description: drop.description,
    objectId: drop.look.kind === "library" ? drop.look.objectId : (library[0]?.id ?? "gift"),
    look: drop.look.kind === "upload" ? drop.look.assetKind : "library",
    upload:
      drop.look.kind === "upload"
        ? {
            kind: drop.look.assetKind,
            localId: null,
            assetId: drop.look.assetId,
            files: drop.assetFiles ? { model: drop.assetFiles.model, thumbnail: drop.assetFiles.thumbnail } : null,
            name: drop.assetFiles?.sourceName ?? (drop.look.assetKind === "photo" ? "Your photo" : "Your model"),
            triangles: drop.assetFiles?.triangles ?? 0,
            originalTriangles: drop.assetFiles?.triangles ?? 0,
            notes: [],
          }
        : null,
    offer: drop.offer
      ? {
          savings: drop.offer.savings,
          terms: drop.offer.terms,
          quantity: drop.offer.quantity,
          perPerson: drop.offer.perPersonLimit,
          rarity: drop.offer.rarity,
          inQuests: drop.offer.inQuests,
        }
      : OFFER_DEFAULTS,
    placement: drop.placement,
    timeZone: drop.timeZone,
    timing: drop.timing,
    audience: drop.audience,
  };
}

/** What to save. An upload must already have its assetId (PublishBox uploads it first). */
export function draftToInput(draft: Draft): DropInput | null {
  if (!draft.placement) return null;
  if (draft.upload && !draft.upload.assetId) return null;
  const round = (n: number) => Math.round(n * 1e7) / 1e7;
  return {
    ...(draft.editing ? { id: draft.editing } : {}),
    type: draft.type,
    ...(draft.type === "offer"
      ? { offer: { ...draft.offer, savings: draft.offer.savings.trim(), terms: draft.offer.terms.trim() } }
      : {}),
    title: draft.title.trim(),
    description: draft.description.trim(),
    objectId: draft.upload ? null : draft.objectId,
    assetId: draft.upload?.assetId ?? null,
    placement: { ...draft.placement, lat: round(draft.placement.lat), lng: round(draft.placement.lng) },
    timeZone: draft.timeZone,
    timing: draft.timing,
    audience: draft.audience,
  };
}

const pad = (n: number) => String(n).padStart(2, "0");

/** "2026-11-21T08:00" for a date in this browser's clock. */
function localStamp(date: Date): string {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

/** Now as "2026-11-21T08:00" in a given time zone. */
function nowIn(timeZone: string): string {
  try {
    const parts = new Intl.DateTimeFormat("en-CA", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    }).formatToParts(new Date());
    const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "00";
    return `${get("year")}-${get("month")}-${get("day")}T${get("hour")}:${get("minute")}`;
  } catch {
    return localStamp(new Date());
  }
}

export function defaultTiming(kind: Timing["kind"]): Timing {
  if (kind === "always") return { kind };
  if (kind === "weekly") return { kind, blocks: [{ days: [1, 2, 3, 4, 5], start: "09:00", end: "17:00" }] };
  const start = new Date();
  start.setMinutes(0, 0, 0);
  start.setHours(start.getHours() + 1);
  const end = new Date(start.getTime() + 3 * 60 * 60 * 1000);
  return { kind, start: localStamp(start), end: localStamp(end) };
}

function blockProblem(block: WeeklyBlock): string | null {
  if (block.days.length === 0) return "Pick at least one day for each set of hours.";
  if (!block.start || !block.end || block.end <= block.start)
    return "Hours have to end after they start, on the same day.";
  return null;
}

/** What still needs fixing before a step is done, in plain words. */
export function problems(draft: Draft, step: Step): string[] {
  const found: string[] = [];
  if (step === 1) {
    const title = draft.title.trim();
    if (!title) found.push("Give it a title.");
    if (title.length > limits.titleMaxChars) found.push(`Keep the title to ${limits.titleMaxChars} characters.`);
    if (draft.description.trim().length > limits.descriptionMaxChars)
      found.push(`Keep the description to ${limits.descriptionMaxChars} characters.`);
    if (draft.type === "offer") found.push(...offerProblems(draft.offer));
    // Never fall back to a ready-made object the person didn't choose.
    if (draft.look !== "library" && draft.upload?.kind !== draft.look)
      found.push(
        `Choose ${draft.look === "photo" ? "a photo" : "a 3D model"} and wait until it's ready, or pick a ready-made object.`,
      );
    if (draft.look === "library" && draft.upload) found.push("Pick a ready-made object.");
  }
  if (step === 2) {
    if (!draft.placement) found.push("Place it on the map.");
  }
  if (step === 3) {
    const t = draft.timing;
    if (t.kind === "once") {
      if (!t.start || !t.end) found.push("Choose when it starts and ends.");
      else if (t.end <= t.start) found.push("It has to end after it starts.");
      else if (t.end <= nowIn(draft.timeZone)) found.push("It has to end in the future.");
    }
    if (t.kind === "weekly") {
      if (t.blocks.length === 0) found.push("Add at least one set of hours, or choose Always.");
      const first = t.blocks.map(blockProblem).find(Boolean);
      if (first) found.push(first);
    }
  }
  return found;
}

function offerProblems(offer: DraftOffer): string[] {
  const found: string[] = [];
  const savings = offer.savings.trim();
  if (!savings) found.push("Say what people get, like \"Buy one coffee, get one free\".");
  if (savings.length > limits.offerSavingsMaxChars)
    found.push(`Keep what people get to ${limits.offerSavingsMaxChars} characters.`);
  if (offer.terms.trim().length > limits.offerTermsMaxChars)
    found.push(`Keep the terms to ${limits.offerTermsMaxChars} characters.`);
  if (!Number.isInteger(offer.quantity) || offer.quantity < 1 || offer.quantity > limits.offerMaxQuantity)
    found.push(`Offer between 1 and ${limits.offerMaxQuantity.toLocaleString("en-US")} in all.`);
  if (!Number.isInteger(offer.perPerson) || offer.perPerson < 1 || offer.perPerson > limits.offerMaxPerPerson)
    found.push(`Each person can claim between 1 and ${limits.offerMaxPerPerson}.`);
  else if (offer.perPerson > offer.quantity) found.push("Each person can't claim more than there are in all.");
  return found;
}

export function allProblems(draft: Draft): { step: Step; message: string }[] {
  return ([1, 2, 3] as Step[]).flatMap((step) => problems(draft, step).map((message) => ({ step, message })));
}
