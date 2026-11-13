// Starting values from the design doc's trust and safety rules.
// Adjust them with real use. The database enforces them too; these are for the UI.

export const limits = {
  titleMaxChars: 70,
  descriptionMaxChars: 400,

  maxSizeMetres: 30,
  maxHeightMetres: 100,

  /** No more than this many public drops within crowdingRadiusMetres of a spot. */
  crowdingMaxDrops: 20,
  crowdingRadiusMetres: 100,

  individualLiveDrops: 10,
  individualNewPerDay: 5,

  photoMaxBytes: 10 * 1024 * 1024,
  glbMaxBytes: 25 * 1024 * 1024,
  glbMaxTriangles: 100_000,

  minimumPostingAge: 18,
} as const;
