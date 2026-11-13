import type { Document } from "@gltf-transform/core";

/** Triangles drawn, counting each place a mesh is used. */
export function countDocumentTriangles(doc: Document): number {
  let total = 0;
  for (const node of doc.getRoot().listNodes()) {
    const mesh = node.getMesh();
    if (!mesh) continue;
    for (const prim of mesh.listPrimitives()) {
      const count = prim.getIndices()?.getCount() ?? prim.getAttribute("POSITION")?.getCount() ?? 0;
      const mode = prim.getMode();
      if (mode === 4) total += Math.floor(count / 3);
      else if (mode === 5 || mode === 6) total += Math.max(0, count - 2);
    }
  }
  return total;
}

/** Mapbox reads indices as 16-bit numbers, so each part can have at most this many vertices. */
export const MAX_VERTICES = 65_535;

export function largestPrimitive(doc: Document): number {
  let most = 0;
  for (const mesh of doc.getRoot().listMeshes())
    for (const prim of mesh.listPrimitives()) most = Math.max(most, prim.getAttribute("POSITION")?.getCount() ?? 0);
  return most;
}
