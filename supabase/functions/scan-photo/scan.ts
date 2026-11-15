// What the photo check looks at: the framed model's structure, and what Google
// Cloud Vision SafeSearch says about each picture. index.ts does the rest.

/** The framed photo the website makes is a box and a picture: about 14 triangles and one texture. */
const MAX_TRIANGLES = 200;
const MAX_PICTURES = 2;

const LEVELS = ["UNKNOWN", "VERY_UNLIKELY", "UNLIKELY", "POSSIBLE", "LIKELY", "VERY_LIKELY"] as const;
type Likelihood = (typeof LEVELS)[number];

/** Flag a picture when a category reaches this likelihood. Adult content is the strictest. */
const FLAG_AT: Record<"adult" | "violence" | "racy" | "medical", Likelihood> = {
  adult: "POSSIBLE",
  violence: "LIKELY",
  racy: "LIKELY",
  medical: "LIKELY",
};

const WORDS: Record<keyof typeof FLAG_AT, string> = {
  adult: "Adult content",
  violence: "Violence",
  racy: "Racy content",
  medical: "Graphic medical content",
};

export type Glb = { triangles: number; images: Uint8Array[]; outsideLinks: boolean };

export type Verdict = {
  name: string;
  adult?: Likelihood;
  violence?: Likelihood;
  racy?: Likelihood;
  medical?: Likelihood;
  error?: string;
};

export type ScanResult = {
  /** Why it needs a person, in plain words. Empty when it's clean. */
  flags: string[];
  triangles: number;
  pictures: Verdict[];
};

/** Reads a GLB's JSON and binary chunks: its triangle count, embedded pictures, and any outside links. */
export function readGlb(bytes: Uint8Array): Glb {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (bytes.byteLength < 20 || view.getUint32(0, true) !== 0x46546c67) throw new Error("The model isn't a GLB file.");
  // deno-lint-ignore no-explicit-any
  let json: any = null;
  let bin: Uint8Array | null = null;
  let offset = 12;
  while (offset + 8 <= bytes.byteLength) {
    const length = view.getUint32(offset, true);
    const type = view.getUint32(offset + 4, true);
    const chunk = bytes.subarray(offset + 8, offset + 8 + length);
    if (type === 0x4e4f534a) json = JSON.parse(new TextDecoder().decode(chunk));
    else if (type === 0x004e4942) bin = chunk;
    offset += 8 + length;
  }
  if (!json) throw new Error("The model has no description.");

  // deno-lint-ignore no-explicit-any
  const outsideLinks = [...(json.buffers ?? []), ...(json.images ?? [])].some((x: any) => typeof x?.uri === "string");

  let triangles = 0;
  for (const mesh of json.meshes ?? []) {
    for (const primitive of mesh.primitives ?? []) {
      const mode = primitive.mode ?? 4;
      const accessor = json.accessors?.[primitive.indices ?? primitive.attributes?.POSITION];
      const count = accessor?.count ?? 0;
      triangles += mode === 4 ? Math.floor(count / 3) : mode === 5 || mode === 6 ? Math.max(count - 2, 0) : 0;
    }
  }

  const images: Uint8Array[] = [];
  for (const image of json.images ?? []) {
    const bufferView = json.bufferViews?.[image.bufferView];
    if (!bufferView || !bin) continue;
    const start = bufferView.byteOffset ?? 0;
    images.push(bin.subarray(start, start + bufferView.byteLength));
  }
  return { triangles, images, outsideLinks };
}

function base64(bytes: Uint8Array): string {
  let text = "";
  for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(text);
}

/** Asks SafeSearch about every picture at once (up to 16 per request). */
export async function safeSearch(apiKey: string, images: { name: string; bytes: Uint8Array }[]): Promise<Verdict[]> {
  const verdicts: Verdict[] = [];
  for (let i = 0; i < images.length; i += 16) {
    const batch = images.slice(i, i + 16);
    const response = await fetch(`https://vision.googleapis.com/v1/images:annotate?key=${encodeURIComponent(apiKey)}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        requests: batch.map((image) => ({
          image: { content: base64(image.bytes) },
          features: [{ type: "SAFE_SEARCH_DETECTION" }],
        })),
      }),
      signal: AbortSignal.timeout(30_000),
    });
    if (!response.ok) throw new Error(`SafeSearch answered ${response.status}: ${(await response.text()).slice(0, 200)}`);
    const body = await response.json();
    batch.forEach((image, j) => {
      const answer = body.responses?.[j] ?? {};
      const s = answer.safeSearchAnnotation ?? {};
      verdicts.push({
        name: image.name,
        adult: s.adult,
        violence: s.violence,
        racy: s.racy,
        medical: s.medical,
        error: answer.error?.message ?? (answer.safeSearchAnnotation ? undefined : "No answer"),
      });
    });
  }
  return verdicts;
}

const atLeast = (value: Likelihood | undefined, level: Likelihood) =>
  LEVELS.indexOf(value ?? "UNKNOWN") >= LEVELS.indexOf(level);

/** The decision: every reason a person should look, in plain words. */
export function judge(glb: Glb, pictures: Verdict[]): ScanResult {
  const flags: string[] = [];
  if (glb.outsideLinks) flags.push("The framed model links to files outside itself.");
  if (glb.triangles > MAX_TRIANGLES) flags.push(`The framed model has ${glb.triangles} triangles, more than a photo frame.`);
  if (glb.images.length === 0) flags.push("The framed model has no picture in it.");
  if (glb.images.length > MAX_PICTURES) flags.push(`The framed model has ${glb.images.length} pictures in it.`);

  for (const picture of pictures) {
    if (picture.error) {
      flags.push(`The ${picture.name} couldn't be checked: ${picture.error}`);
      continue;
    }
    for (const category of Object.keys(FLAG_AT) as (keyof typeof FLAG_AT)[]) {
      const value = picture[category];
      if (atLeast(value, FLAG_AT[category]) || (category === "adult" && (value ?? "UNKNOWN") === "UNKNOWN")) {
        const level = (value ?? "UNKNOWN").toLowerCase().replace("_", " ");
        flags.push(`${WORDS[category]} in the ${picture.name}: ${level}.`);
      }
    }
  }
  return { flags, triangles: glb.triangles, pictures };
}
