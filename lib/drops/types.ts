// Everything on the map is a drop, with one of three types. One add flow,
// one card design and one review process cover all of them.

export type DropType = "object" | "message" | "offer";

export type DropStatus = "draft" | "in_review" | "live" | "paused" | "rejected";

export type Audience = "everyone" | "link";

/** What the drop looks like: a ready-made object, a framed photo, or an uploaded GLB. */
export type Look =
  | { kind: "library"; objectId: string }
  | { kind: "photo"; assetId: string }
  | { kind: "glb"; assetId: string };

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
export type PublicDrop = Drop & { owner: Owner; offer?: Offer };
