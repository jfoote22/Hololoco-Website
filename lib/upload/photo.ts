// Turns a photo into what the map needs: the photo re-drawn (which drops its
// location and other metadata), a framed-photo model 1 m across standing on the
// ground, and a square thumbnail. Runs in the browser; load it dynamically.

import * as THREE from "three";
import { GLTFExporter } from "three/addons/exporters/GLTFExporter.js";
import { megabytes, uploadLimits } from "./limits";
import { UploadError, type ProcessedUpload } from "./types";

type Progress = (message: string) => void;

const FRAME_COLOR = 0xf2f5f7;

function formatOf(file: File): ProcessedUpload["sourceFormat"] {
  const type = file.type.toLowerCase();
  if (type === "image/jpeg") return "jpeg";
  if (type === "image/png") return "png";
  if (type === "image/webp") return "webp";
  if (type === "image/heic" || type === "image/heif" || /\.hei[cf]$/i.test(file.name)) return "heic";
  return "other";
}

function scaled(source: ImageBitmap, longest: number): HTMLCanvasElement {
  const ratio = Math.min(1, longest / Math.max(source.width, source.height));
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(source.width * ratio));
  canvas.height = Math.max(1, Math.round(source.height * ratio));
  const context = canvas.getContext("2d");
  if (!context) throw new UploadError("This browser can't work with photos.");
  context.imageSmoothingQuality = "high";
  context.drawImage(source, 0, 0, canvas.width, canvas.height);
  return canvas;
}

function squareCrop(source: ImageBitmap, side: number): HTMLCanvasElement {
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = side;
  const context = canvas.getContext("2d");
  if (!context) throw new UploadError("This browser can't work with photos.");
  const crop = Math.min(source.width, source.height);
  context.imageSmoothingQuality = "high";
  context.drawImage(source, (source.width - crop) / 2, (source.height - crop) / 2, crop, crop, 0, 0, side, side);
  return canvas;
}

function toBlob(canvas: HTMLCanvasElement, type: string, quality?: number): Promise<Blob> {
  return new Promise((resolve, reject) =>
    canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new UploadError("Couldn't save the photo."))), type, quality),
  );
}

/** The photo in a light frame, 1 m across at its widest, standing on the ground. */
async function framedPhoto(picture: HTMLCanvasElement): Promise<Blob> {
  const aspect = picture.width / picture.height;
  const width = aspect >= 1 ? 1 : aspect;
  const height = aspect >= 1 ? 1 / aspect : 1;
  const border = 0.04;
  const depth = 0.04;

  const texture = new THREE.CanvasTexture(picture);
  texture.colorSpace = THREE.SRGBColorSpace;
  texture.userData.mimeType = "image/jpeg";

  const group = new THREE.Group();
  const frame = new THREE.Mesh(
    new THREE.BoxGeometry(width + border * 2, height + border * 2, depth),
    new THREE.MeshStandardMaterial({ color: FRAME_COLOR, roughness: 0.6, metalness: 0 }),
  );
  frame.position.set(0, (height + border * 2) / 2, 0);
  const photo = new THREE.Mesh(
    new THREE.PlaneGeometry(width, height),
    new THREE.MeshStandardMaterial({ map: texture, roughness: 0.9, metalness: 0 }),
  );
  photo.position.set(0, border + height / 2, depth / 2 + 0.002);
  group.add(frame, photo);

  // Shrink to fit 1 m if the frame makes it wider than that.
  const scale = 1 / Math.max(width + border * 2, height + border * 2);
  group.scale.setScalar(scale);

  const glb = (await new GLTFExporter().parseAsync(group, {
    binary: true,
    maxTextureSize: uploadLimits.textureSide,
  })) as ArrayBuffer;
  texture.dispose();
  return new Blob([glb], { type: "model/gltf-binary" });
}

export async function processPhoto(file: File, progress: Progress): Promise<ProcessedUpload> {
  if (file.size > uploadLimits.photoSourceBytes)
    throw new UploadError(`That photo is ${megabytes(file.size)}. Photos can be up to ${megabytes(uploadLimits.photoSourceBytes)}.`);

  progress("Reading the photo…");
  let bitmap: ImageBitmap;
  try {
    bitmap = await createImageBitmap(file, { imageOrientation: "from-image" });
  } catch {
    throw new UploadError(
      formatOf(file) === "heic"
        ? "This browser can't open HEIC photos. Choose a JPEG or PNG, or set your phone's camera to “Most Compatible”."
        : "Couldn't open that file as a photo. Choose a JPEG, PNG or WebP.",
    );
  }

  try {
    // Drawing it again keeps the pixels and drops everything else, including location.
    const photo = await toBlob(scaled(bitmap, uploadLimits.photoSide), "image/jpeg", 0.86);
    progress("Putting it in a frame…");
    const glb = await framedPhoto(scaled(bitmap, uploadLimits.textureSide));
    const thumbnail = await toBlob(squareCrop(bitmap, 256), "image/png");
    return {
      kind: "photo",
      glb,
      thumbnail,
      photo,
      triangles: 14,
      originalTriangles: 14,
      sourceName: file.name,
      sourceFormat: formatOf(file),
      notes: [],
    };
  } finally {
    bitmap.close();
  }
}
