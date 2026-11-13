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

/** Public offer fields. The promo code lives in its own table and only a claim returns it. */
export type Offer = {
  dropId: string;
  /** Shown as written, e.g. "$3". */
  savings: string;
  quantity: number;
  remaining: number;
  perPersonLimit: number;
  terms: string;
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

/** Set by the database: an account's drops are reviewed until one is approved. */
export type Review = "pending" | "approved" | "rejected";

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
};

/** What the add flow sends to the database (save_drop). No id means a new drop. */
export type DropInput = {
  id?: string;
  type: "object" | "message";
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
