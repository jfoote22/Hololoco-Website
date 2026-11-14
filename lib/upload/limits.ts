// Limits for uploaded photos and models. Objects are small on the map (a few
// dozen to a couple of hundred pixels), so models are simplified hard.
// The database and Storage enforce the hard edges too: 20,000 triangles as
// reported, 8 MB per file, and only GLB, PNG and JPEG files.

export const uploadLimits = {
  /** Most triangles a model may have after simplifying. */
  modelTriangles: 20_000,
  /** Most triangles a chosen model may have before simplifying: what AI and scanning tools commonly export. */
  modelSourceTriangles: 1_500_000,
  /** Longest side of any texture after resizing, in pixels. */
  textureSide: 1024,
  /** The processed model file. Storage refuses anything over 8 MB. */
  modelBytes: 6 * 1024 * 1024,
  /**
   * What people can choose: a model file and its textures together. An 80 MB,
   * 1.5-million-triangle GLB peaks at about 560 MB of memory while processing.
   */
  modelSourceBytes: 150 * 1024 * 1024,
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
