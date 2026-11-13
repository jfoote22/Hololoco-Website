// What a reviewer's browser checks in an uploaded model, from the actual file
// (not anything the uploader's browser reported): it's a self-contained GLB, its
// triangles, size and textures are within limits, and what it really looks like.

import { WebIO } from "@gltf-transform/core";
import { ALL_EXTENSIONS } from "@gltf-transform/extensions";
import { countDocumentTriangles, largestPrimitive, MAX_VERTICES } from "./count";
import { megabytes, uploadLimits } from "./limits";
import { renderThumbnail } from "./model";

export type Inspection = {
  triangles: number;
  bytes: number;
  largestTexture: number;
  /** A fresh picture of the actual model. */
  picture: Blob | null;
  pictureUrl: string | null;
  /** Reasons it can't be approved, in plain words. Empty when it's fine. */
  problems: string[];
};

const fmt = (n: number) => n.toLocaleString("en-US");

/** The JSON part of a GLB, read without loading anything it points to. */
function glbJson(bytes: Uint8Array): { buffers?: { uri?: string }[]; images?: { uri?: string }[] } {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (bytes.byteLength < 20 || view.getUint32(0, true) !== 0x46546c67) throw new Error("not a GLB");
  const length = view.getUint32(12, true);
  if (view.getUint32(16, true) !== 0x4e4f534a) throw new Error("no JSON chunk");
  return JSON.parse(new TextDecoder().decode(bytes.subarray(20, 20 + length)));
}

export async function inspectModel(url: string): Promise<Inspection> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Couldn't download the model (${response.status}).`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  const problems: string[] = [];

  let json: ReturnType<typeof glbJson>;
  try {
    json = glbJson(bytes);
  } catch {
    return { triangles: 0, bytes: bytes.byteLength, largestTexture: 0, picture: null, pictureUrl: null, problems: ["It isn't a GLB model file."] };
  }
  const external = [...(json.buffers ?? []), ...(json.images ?? [])].some((x) => x.uri && !x.uri.startsWith("data:"));
  if (external) {
    return {
      triangles: 0,
      bytes: bytes.byteLength,
      largestTexture: 0,
      picture: null,
      pictureUrl: null,
      problems: ["It points to files outside itself, which isn't allowed."],
    };
  }

  const doc = await new WebIO().registerExtensions(ALL_EXTENSIONS).readBinary(bytes);
  const triangles = countDocumentTriangles(doc);
  let largestTexture = 0;
  for (const texture of doc.getRoot().listTextures()) {
    const size = texture.getSize();
    if (size) largestTexture = Math.max(largestTexture, size[0], size[1]);
  }

  if (triangles > uploadLimits.modelTriangles)
    problems.push(`It has ${fmt(triangles)} triangles; the limit is ${fmt(uploadLimits.modelTriangles)}.`);
  if (bytes.byteLength > uploadLimits.modelBytes)
    problems.push(`It's ${megabytes(bytes.byteLength)}; the limit is ${megabytes(uploadLimits.modelBytes)}.`);
  if (largestPrimitive(doc) > MAX_VERTICES) problems.push("One part has more vertices than the map can draw.");
  if (largestTexture > uploadLimits.textureSide)
    problems.push(`A texture is ${largestTexture} px; the limit is ${uploadLimits.textureSide} px.`);

  let picture: Blob | null = null;
  try {
    picture = await renderThumbnail(bytes);
  } catch {
    problems.push("It couldn't be drawn, so it may be broken.");
  }

  return {
    triangles,
    bytes: bytes.byteLength,
    largestTexture,
    picture,
    pictureUrl: picture ? URL.createObjectURL(picture) : null,
    problems,
  };
}
