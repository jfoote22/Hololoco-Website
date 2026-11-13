// Limits for uploaded photos and models. Objects are small on the map (a few
// dozen to a couple of hundred pixels), so models are simplified hard.
// The database and Storage enforce the hard edges too: 10,000 triangles as
// reported, 8 MB per file, and only GLB, PNG and JPEG files.

export const uploadLimits = {
  /** Most triangles a model may have after simplifying. */
  modelTriangles: 10_000,
  /** Longest side of any texture after resizing, in pixels. */
  textureSide: 1024,
  /** The processed model file. Storage refuses anything over 8 MB. */
  modelBytes: 6 * 1024 * 1024,
  /** What people can choose: a model file and its textures together. */
  modelSourceBytes: 60 * 1024 * 1024,
  /** Longest side of the photo shown on the drop's page, in pixels. */
  photoSide: 1600,
  photoSourceBytes: 25 * 1024 * 1024,
  /** Uploads per account per day. */
  perDay: 10,
} as const;

export function megabytes(bytes: number): string {
  const mb = bytes / (1024 * 1024);
  return `${mb < 10 ? mb.toFixed(1) : Math.round(mb)} MB`;
}
