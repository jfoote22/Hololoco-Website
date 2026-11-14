// Turns a GLB or FBX (plus any texture files chosen with it) into a small GLB for
// the map: static, standard materials, textures capped, 1 m across, centred and
// on the ground, simplified to the triangle budget, with a thumbnail.
// Runs in the browser; load it with a dynamic import, it's large.

import { Primitive, VertexLayout, WebIO, type Document, type Transform } from "@gltf-transform/core";
import { ALL_EXTENSIONS } from "@gltf-transform/extensions";
import { compactPrimitive, dedup, prune, simplify, weld } from "@gltf-transform/functions";
import { MeshoptSimplifier } from "meshoptimizer";
import * as THREE from "three";
import { GLTFExporter } from "three/addons/exporters/GLTFExporter.js";
import { FBXLoader } from "three/addons/loaders/FBXLoader.js";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { TGALoader } from "three/addons/loaders/TGALoader.js";
import { countDocumentTriangles, largestPrimitive, MAX_VERTICES } from "./count";
import { megabytes, uploadLimits } from "./limits";
import { UploadError, type ProcessedUpload } from "./types";

type Progress = (message: string) => void;

const fmt = (n: number) => n.toLocaleString("en-US");
const baseName = (path: string) => path.split(/[\\/]/).pop()?.toLowerCase() ?? path.toLowerCase();

export async function processModel(files: File[], progress: Progress): Promise<ProcessedUpload> {
  const main = files.find((f) => /\.(glb|fbx)$/i.test(f.name));
  if (!main) throw new UploadError("Choose a .glb or .fbx file. Texture images can come along with it.");
  const total = files.reduce((sum, f) => sum + f.size, 0);
  if (total > uploadLimits.modelSourceBytes)
    throw new UploadError(
      `Those files add up to ${megabytes(total)}. A model and its textures can be up to ${megabytes(uploadLimits.modelSourceBytes)}.`,
    );
  const format = main.name.toLowerCase().endsWith(".fbx") ? "fbx" : "glb";

  progress("Reading the model…");
  const { root, missing } = await load(main, format, files.filter((f) => f !== main), progress);

  progress("Preparing it for the map…");
  prepare(root);
  const holder = normalize(root);
  const originalTriangles = countTriangles(holder);
  if (originalTriangles === 0) throw new UploadError("That file has no shapes in it to show.");
  if (originalTriangles > uploadLimits.modelSourceTriangles)
    throw new UploadError(
      `That model has ${fmt(originalTriangles)} triangles. Models can have up to ${fmt(uploadLimits.modelSourceTriangles)}; most 3D tools can reduce it when exporting.`,
    );

  const exported = new Uint8Array(
    (await new GLTFExporter().parseAsync(holder, {
      binary: true,
      onlyVisible: true,
      maxTextureSize: uploadLimits.textureSide,
    })) as ArrayBuffer,
  );

  progress(
    originalTriangles > uploadLimits.modelTriangles
      ? `Simplifying ${fmt(originalTriangles)} triangles to ${fmt(uploadLimits.modelTriangles)} or fewer…`
      : "Tidying it up…",
  );
  const { glb, triangles } = await shrink(exported);
  if (glb.byteLength > uploadLimits.modelBytes)
    throw new UploadError(
      `Even simplified, it comes to ${megabytes(glb.byteLength)}, mostly textures. Models can be up to ${megabytes(uploadLimits.modelBytes)}; try fewer or smaller textures.`,
    );

  progress("Making a preview…");
  const thumbnail = await renderThumbnail(glb);

  return {
    kind: "model",
    glb: new Blob([glb as Uint8Array<ArrayBuffer>], { type: "model/gltf-binary" }),
    thumbnail,
    triangles,
    originalTriangles,
    sourceName: main.name,
    sourceFormat: format,
    notes: missing.length
      ? [`These textures weren't included, so parts may look plain: ${missing.join(", ")}. Choose them together with the model.`]
      : [],
  };
}

/** Load with three.js. Texture files chosen alongside are matched by file name. */
async function load(main: File, format: "glb" | "fbx", extras: File[], progress: Progress) {
  const byName = new Map(extras.map((f) => [baseName(f.name), URL.createObjectURL(f)]));
  const missing = new Set<string>();
  const manager = new THREE.LoadingManager();
  // FBX files often use TGA textures; the browser can't open those by itself.
  manager.addHandler(/\.tga$/i, new TGALoader(manager));
  manager.setURLModifier((url) => {
    if (url.startsWith("blob:") || url.startsWith("data:")) return url;
    let name = baseName(url);
    try {
      name = baseName(decodeURIComponent(url));
    } catch {
      // Keep the raw name.
    }
    return byName.get(name) ?? url;
  });

  let started = false;
  const settled = new Promise<void>((resolve) => {
    manager.onLoad = () => resolve();
  });
  manager.onStart = () => {
    started = true;
  };
  manager.onError = (url) => {
    if (!url.startsWith("blob:") && !url.startsWith("data:")) missing.add(baseName(url));
  };

  const buffer = await main.arrayBuffer();
  progress(`Opening ${main.name}…`);
  let root: THREE.Object3D;
  try {
    if (format === "glb") {
      root = (await new GLTFLoader(manager).parseAsync(buffer, "")).scene;
    } else {
      root = new FBXLoader(manager).parse(buffer, "");
    }
  } catch (error) {
    console.warn("Couldn't read the model:", error);
    throw new UploadError(
      format === "fbx"
        ? "Couldn't read that FBX file. Binary and text FBX from 2011 on work best; try exporting it again or as GLB."
        : "Couldn't read that GLB file. Try exporting it again.",
    );
  }

  // Wait for textures (FBX loads them after parsing), but not forever.
  if (started) {
    progress("Loading its textures…");
    await Promise.race([settled, new Promise((r) => setTimeout(r, 20_000))]);
  }
  for (const url of byName.values()) URL.revokeObjectURL(url);
  return { root, missing: [...missing] };
}

/** Static meshes with standard materials only: no lights, cameras, skins, morphs or animation. */
function prepare(root: THREE.Object3D) {
  const drop: THREE.Object3D[] = [];
  const swaps: [THREE.Object3D, THREE.Mesh][] = [];
  root.traverse((object) => {
    object.animations = [];
    if ((object as THREE.Light).isLight || (object as THREE.Camera).isCamera) drop.push(object);
    else if ((object as THREE.Points).isPoints || (object as THREE.Line).isLine) drop.push(object);
    else if ((object as THREE.Mesh).isMesh) {
      const mesh = object as THREE.Mesh;
      const geometry = mesh.geometry;
      geometry.morphAttributes = {};
      geometry.deleteAttribute("skinIndex");
      geometry.deleteAttribute("skinWeight");
      const material = Array.isArray(mesh.material) ? mesh.material.map(toStandard) : toStandard(mesh.material);
      if ((mesh as THREE.SkinnedMesh).isSkinnedMesh) {
        // Keep the shape in its rest pose as a plain mesh.
        const plain = new THREE.Mesh(geometry, material);
        plain.name = mesh.name;
        plain.position.copy(mesh.position);
        plain.quaternion.copy(mesh.quaternion);
        plain.scale.copy(mesh.scale);
        swaps.push([mesh, plain]);
      } else {
        mesh.material = material;
        mesh.morphTargetInfluences = undefined;
        mesh.morphTargetDictionary = undefined;
      }
    }
  });
  for (const object of drop) object.parent?.remove(object);
  for (const [from, to] of swaps) {
    const parent = from.parent;
    if (!parent) continue;
    parent.add(to);
    for (const child of [...from.children]) to.add(child);
    parent.remove(from);
  }
}

type AnyMaterial = THREE.Material & {
  color?: THREE.Color;
  map?: THREE.Texture | null;
  emissive?: THREE.Color;
  emissiveMap?: THREE.Texture | null;
  normalMap?: THREE.Texture | null;
};

function toStandard(material: THREE.Material): THREE.Material {
  const m = material as AnyMaterial;
  const out =
    (material as THREE.MeshStandardMaterial).isMeshStandardMaterial
      ? (material as THREE.MeshStandardMaterial)
      : new THREE.MeshStandardMaterial({
          name: m.name,
          color: m.color ?? new THREE.Color(0xffffff),
          map: m.map ?? null,
          emissive: m.emissive ?? new THREE.Color(0x000000),
          emissiveMap: m.emissiveMap ?? null,
          normalMap: m.normalMap ?? null,
          transparent: m.transparent,
          opacity: m.opacity,
          alphaTest: m.alphaTest,
          side: m.side,
          vertexColors: m.vertexColors,
          roughness: 0.8,
          metalness: 0,
        });
  // Colour textures without see-through parts are much smaller as JPEG.
  const opaque = !out.transparent && out.alphaTest === 0;
  if (out.map && opaque) out.map.userData.mimeType = "image/jpeg";
  if (out.emissiveMap) out.emissiveMap.userData.mimeType = "image/jpeg";
  return out;
}

/** 1 m across at its widest, centred, sitting on the ground, like the ready-made objects. */
function normalize(root: THREE.Object3D): THREE.Group {
  root.updateMatrixWorld(true);
  const box = new THREE.Box3().setFromObject(root);
  if (box.isEmpty()) throw new UploadError("That file has no shapes in it to show.");
  const size = box.getSize(new THREE.Vector3());
  const longest = Math.max(size.x, size.y, size.z);
  if (!Number.isFinite(longest) || longest <= 0) throw new UploadError("That model has no size, so it can't be shown.");
  const center = box.getCenter(new THREE.Vector3());

  const inner = new THREE.Group();
  inner.position.set(-center.x, -box.min.y, -center.z);
  inner.add(root);
  const holder = new THREE.Group();
  holder.scale.setScalar(1 / longest);
  holder.add(inner);
  holder.updateMatrixWorld(true);
  return holder;
}

function countTriangles(root: THREE.Object3D): number {
  let total = 0;
  root.traverse((object) => {
    const mesh = object as THREE.Mesh;
    if (!mesh.isMesh) return;
    const g = mesh.geometry;
    total += Math.floor((g.index ? g.index.count : (g.getAttribute("position")?.count ?? 0)) / 3);
  });
  return total;
}

/**
 * Simplifies across texture seams, which the gentle passes can't, while counting
 * texture coordinates and normals in the error so it avoids collapses that would
 * smear the texture. Also drops tiny loose bits.
 */
function simplifyAcrossSeams(ratio: number): Transform {
  return (doc) => {
    for (const mesh of doc.getRoot().listMeshes())
      for (const prim of mesh.listPrimitives()) {
        const position = prim.getAttribute("POSITION");
        const oldIndices = prim.getIndices();
        if (prim.getMode() !== Primitive.Mode.TRIANGLES || !position || !oldIndices) continue;
        const count = position.getCount();
        const uv = prim.getAttribute("TEXCOORD_0")?.getArray();
        const normal = prim.getAttribute("NORMAL")?.getArray();
        const stride = (uv ? 2 : 0) + (normal ? 3 : 0);
        const weights = [...(uv ? [1, 1] : []), ...(normal ? [0.25, 0.25, 0.25] : [])];
        const attributes = new Float32Array(Math.max(1, count * stride));
        for (let v = 0; v < count; v++) {
          let o = v * stride;
          if (uv) for (let k = 0; k < 2; k++) attributes[o++] = uv[v * 2 + k];
          if (normal) for (let k = 0; k < 3; k++) attributes[o++] = normal[v * 3 + k];
        }
        const indices = new Uint32Array(oldIndices.getArray()!);
        const target = Math.floor((ratio * indices.length) / 3) * 3;
        const [kept] = MeshoptSimplifier.simplifyWithAttributes(
          indices,
          new Float32Array(position.getArray()!),
          3,
          attributes,
          Math.max(1, stride),
          weights,
          null,
          target,
          1,
          ["Permissive", "Prune"],
        );
        prim.setIndices(doc.createAccessor().setType("SCALAR").setBuffer(oldIndices.getBuffer()).setArray(kept as Uint32Array<ArrayBuffer>));
        if (oldIndices.listParents().length === 1) oldIndices.dispose();
        compactPrimitive(prim);
      }
  };
}

/** Ignores the surface's structure altogether, so it always reaches the target, but roughly. */
const sloppy: typeof MeshoptSimplifier = {
  ...MeshoptSimplifier,
  simplify: (indices, positions, stride, target, error) =>
    MeshoptSimplifier.simplifySloppy(indices, positions, stride, null, target, error),
};

// From gentlest to roughest; the first that fits the budget wins. Models with lots of
// texture seams (common in scanned and AI-made ones) usually need the seams pass.
const PASSES: { kind: "gentle" | "seams" | "rough"; transform: (ratio: number) => Transform }[] = [
  ...[0.002, 0.01, 0.03, 0.08, 0.2, 0.5].map((error) => ({
    kind: "gentle" as const,
    transform: (ratio: number) => simplify({ simplifier: MeshoptSimplifier, ratio, error }),
  })),
  { kind: "seams", transform: simplifyAcrossSeams },
  { kind: "rough", transform: (ratio) => simplify({ simplifier: sloppy, ratio, error: 1 }) },
];

/** Mapbox reads indices as 16-bit numbers, so store them that way. */
function shortIndices(doc: Document) {
  for (const mesh of doc.getRoot().listMeshes())
    for (const prim of mesh.listPrimitives()) {
      const indices = prim.getIndices();
      const array = indices?.getArray();
      if (indices && array instanceof Uint32Array && (prim.getAttribute("POSITION")?.getCount() ?? 0) <= MAX_VERTICES)
        indices.setArray(new Uint16Array(array));
    }
}

/** Merge duplicates, then simplify with meshoptimizer until it fits the budget. */
async function shrink(bytes: Uint8Array): Promise<{ glb: Uint8Array; triangles: number }> {
  await MeshoptSimplifier.ready;
  // Mapbox's model loader reads each vertex attribute from its own buffer view,
  // so the file must not interleave them.
  const io = new WebIO().registerExtensions(ALL_EXTENSIONS).setVertexLayout(VertexLayout.SEPARATE);
  const budget = uploadLimits.modelTriangles;

  let doc = await io.readBinary(bytes);
  await doc.transform(dedup(), weld());
  let triangles = countDocumentTriangles(doc);

  if (triangles > budget) {
    const start = triangles;
    // Each pass starts again from the merged model, kept as bytes.
    const welded = await io.writeBinary(doc);
    let best: { doc: Document; triangles: number } | null = null;
    const ratio = Math.min(1, (budget / start) * 0.95);
    let previous = start;
    let stuck: string | null = null;
    for (const [pass, { kind, transform }] of PASSES.entries()) {
      // Once allowing more error stops helping, go straight to the next kind of pass.
      if (kind === stuck) continue;
      const attempt = await io.readBinary(welded);
      await attempt.transform(transform(ratio), prune());
      const count = countDocumentTriangles(attempt);
      if (process.env.NODE_ENV === "development")
        console.info(`[upload] pass ${pass + 1} of ${PASSES.length} (${kind}): ${fmt(count)} triangles`);
      if (!best || count < best.triangles) best = { doc: attempt, triangles: count };
      if (count <= budget) break;
      if (count > previous * 0.98) stuck = kind;
      previous = count;
    }
    if (!best || best.triangles > budget)
      throw new UploadError(
        `Couldn't simplify it below ${fmt(budget)} triangles (got to ${fmt(best?.triangles ?? start)}). Try a simpler model.`,
      );
    doc = best.doc;
    triangles = best.triangles;
  }

  await doc.transform(prune());
  shortIndices(doc);
  if (largestPrimitive(doc) > MAX_VERTICES)
    throw new UploadError("One part of it is still too detailed for the map. Try a simpler model.");
  return { glb: await io.writeBinary(doc), triangles };
}

/** A 256 px picture of the model, lit and framed like the ready-made objects. */
export async function renderThumbnail(glb: Uint8Array): Promise<Blob> {
  const buffer = glb.buffer.slice(glb.byteOffset, glb.byteOffset + glb.byteLength) as ArrayBuffer;
  const gltf = await new GLTFLoader().parseAsync(buffer, "");
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = 256;
  const renderer = new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true, preserveDrawingBuffer: true });
  try {
    renderer.setPixelRatio(1);
    renderer.setSize(256, 256, false);
    renderer.setClearColor(0x000000, 0);
    const scene = new THREE.Scene();
    scene.add(new THREE.HemisphereLight(0xffffff, 0xbfc9cf, 2.6));
    const sun = new THREE.DirectionalLight(0xffffff, 2.2);
    sun.position.set(1, 2, 3);
    scene.add(sun);
    scene.add(gltf.scene);
    const camera = new THREE.PerspectiveCamera(32, 1, 0.1, 10);
    camera.position.set(1.05, 1.1, 1.95);
    camera.lookAt(0, 0.45, 0);
    renderer.render(scene, camera);
    return await new Promise<Blob>((resolve, reject) =>
      canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new UploadError("Couldn't make a preview."))), "image/png"),
    );
  } finally {
    renderer.dispose();
    renderer.forceContextLoss();
  }
}
