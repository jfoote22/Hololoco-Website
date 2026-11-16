// Everything on the map is a drop, with one of three types. One add flow,
// one card design and one review process cover all of them.

export type DropType = "object" | "message" | "offer";

export type DropStatus = "draft" | "in_review" | "live" | "paused" | "rejected";

export type Audience = "everyone" | "link";

/** A photo or 3D model someone uploaded. Public files exist only once staff approve it. */
export type UploadLook = {
  kind: "upload";
  assetId: string;
  assetKind: "photo" | "model";
  status: "pending" | "approved" | "rejected";
  /** Paths in the public drop-assets bucket, or null until approved. */
  model: string | null;
  thumbnail: string | null;
  photo: string | null;
};

/** What the drop looks like: a ready-made object, or an uploaded photo (in a frame) or model. */
export type Look = { kind: "library"; objectId: string } | UploadLook;

/** The private files of the person's own upload (or any, for staff), in the uploads bucket. */
export type AssetFiles = {
  model: string;
  thumbnail: string;
  photo: string | null;
  triangles: number | null;
  sourceName: string | null;
  sourceFormat: string;
};

export type Placement = {
  lat: number;
  lng: number;
  /** Metres above ground. */
  height: number;
  /** Metres across. */
  size: number;
  /** Degrees clockwise from north. */
  turn: number;
};

/** 0 = Sunday … 6 = Saturday. */
export type Weekday = 0 | 1 | 2 | 3 | 4 | 5 | 6;

/** Times are "HH:MM" in the drop's own time zone. */
export type WeeklyBlock = { days: Weekday[]; start: string; end: string };

export type Timing =
  | { kind: "always" }
  | { kind: "once"; start: string; end: string }
  | { kind: "weekly"; blocks: WeeklyBlock[] };

export type Drop = {
  id: string;
  type: DropType;
  ownerId: string;
  title: string;
  description: string;
  look: Look;
  placement: Placement;
  /** IANA zone, e.g. "America/Chicago". Schedules use it, not the viewer's zone. */
  timeZone: string;
  timing: Timing;
  audience: Audience;
  status: DropStatus;
};

/**
 * How rare an offer is, set by the business: how it looks in the app, how often
 * people come across it, and which stage of a quest it can be in.
 */
export type Rarity = "common" | "uncommon" | "rare";

/** deal: a coupon or discount. giveaway: something free. gift_card: a gift card or certificate. */
export type OfferKind = "deal" | "giveaway" | "gift_card";

/** Public offer fields. */
export type Offer = {
  /** What people get, shown as written, e.g. "Buy one coffee, get one free". */
  savings: string;
  quantity: number;
  remaining: number;
  perPersonLimit: number;
  terms: string;
  rarity: Rarity;
  /** The business lets Hololoco link it into quests with other businesses nearby. */
  inQuests: boolean;
  kind: OfferKind;
  /** What kind of business it's from (lib/drops/categories.ts). Quests of one category get a theme. */
  category: string;
  /** Players can trade it, or leave it on the map for someone else. */
  tradeable: boolean;
  /** What it's worth in US cents, if the business said. */
  valueCents: number | null;
  /** It loses this share of its value every decayDays days after it's posted (0: it doesn't). */
  decayPercent: number;
  decayDays: number;
  /** What it's worth now, worked out by the database. */
  valueNowCents: number | null;
};

/** The public face of whoever posted a drop. */
export type Owner = {
  name: string;
  kind: "individual" | "business";
  /** Businesses only: set by staff after a verification check. */
  verified: boolean;
};

/** A drop as a visitor sees it: the drop, its owner's public name, and an offer's public fields. */
export type PublicDrop = Drop & {
  owner: Owner;
  offer?: Offer;
  /** One of the made-up drops in lib/drops/sample.ts. */
  sample?: boolean;
  /**
   * Addresses to show this drop with before it's public, for its owner or staff
   * (short-lived signed links to the private upload).
   */
  preview?: { model?: string; thumbnail?: string; photo?: string };
};

/** Set by the database: every new or changed drop waits for the automatic check, or a person. */
export type Review = "pending" | "approved" | "rejected";

/**
 * The automatic check on a drop. While it's going, only `state`; once it's done
 * (or has handed the drop to a person), what it said.
 */
export type DropCheck = {
  state: "queued" | "running" | "retry" | "done" | "failed";
  /** What happened: approved, or held for a person. */
  applied?: "approve" | "hold" | "ignored";
  /** What the check says to the owner, if anything. */
  ownerNote?: string;
  suggestedRarity?: Rarity;
  rarityReason?: string;
  placementTip?: string;
  /** Staff only. */
  decision?: "approve" | "hold";
  reason?: string;
  concerns?: string[];
  error?: string;
  model?: string;
};

/** One of the signed-in person's own drops, with what only they see. */
export type MyDrop = PublicDrop & {
  review: Review;
  /** Why staff didn't approve it, shown to the owner. */
  reviewReason: string | null;
  paused: boolean;
  /** Within its hours right now, in its own time zone. */
  openNow: boolean;
  createdAt: string;
  /** Hidden from the map while staff check a report about it. */
  hiddenForReport: boolean;
  /** Its upload's private files, if it uses one. */
  assetFiles: AssetFiles | null;
  /** The automatic check, or null for drops that never had one. */
  check: DropCheck | null;
  /** The quest this offer is a stage of, if any. */
  quest: QuestPlace | null;
  /** Where its photo is in the automatic photo check, if it uses a photo. */
  photoCheck: PhotoCheckState | null;
  /** How many people captured it, and (offers) redeemed it. */
  stats: { captures: number; redeemed: number | null } | null;
};

/** The automatic photo check: queued and running while it looks; done once it has decided; failed if it couldn't. */
export type PhotoCheckState = "queued" | "running" | "done" | "failed";

/** What the photo check found, for staff. */
export type PhotoCheck = {
  state: PhotoCheckState | null;
  result: { flags?: string[]; error?: string } | null;
};

/** Which quest an offer is in, and where. */
export type QuestPlace = { id: string; name: string; position: number; stageCount: number };

/** An offer as the add flow sends it. */
export type OfferInput = {
  savings: string;
  terms: string;
  quantity: number;
  perPerson: number;
  rarity: Rarity;
  inQuests: boolean;
  kind: OfferKind;
  category: string;
  tradeable: boolean;
  valueCents: number | null;
  decayPercent: number;
  decayDays: number;
};

/** What the add flow sends to the database (save_drop). No id means a new drop. */
export type DropInput = {
  id?: string;
  type: DropType;
  /** Offers only. */
  offer?: OfferInput;
  title: string;
  description: string;
  /** A ready-made object, or null when the drop uses an upload. */
  objectId: string | null;
  assetId: string | null;
  placement: Placement;
  timeZone: string;
  timing: Timing;
  audience: Audience;
};
