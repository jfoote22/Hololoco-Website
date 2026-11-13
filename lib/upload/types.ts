/** A photo or model processed in the browser, ready to upload. */
export type ProcessedUpload = {
  kind: "photo" | "model";
  /** The model the map draws: simplified, textures capped, 1 m across, on the ground. */
  glb: Blob;
  /** 256 px PNG. */
  thumbnail: Blob;
  /** Photos only: the cleaned-up photo (no location data) for the drop's page. */
  photo?: Blob;
  triangles: number;
  /** Triangles before simplifying. */
  originalTriangles: number;
  sourceName: string;
  sourceFormat: "glb" | "fbx" | "jpeg" | "png" | "webp" | "heic" | "other";
  /** Things worth telling the person, like textures that weren't included. */
  notes: string[];
};

/** A problem to show the person, in plain words. */
export class UploadError extends Error {}
