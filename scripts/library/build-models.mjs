// Builds the ready-made object library as GLB files in public/library/.
// Each object is made from simple shapes, scaled to fit a 1 m box, centred,
// and sitting on y = 0, so a drop's size and height map straight onto it.
//
// Run: node scripts/library/build-models.mjs
// Then: node scripts/library/render-thumbnails.mjs (needs Chrome) for the PNG thumbnails.

import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import * as THREE from "three";
import { GLTFExporter } from "three/addons/exporters/GLTFExporter.js";
import { mergeVertices } from "three/addons/utils/BufferGeometryUtils.js";

// GLTFExporter reads its output through FileReader, which Node doesn't have.
globalThis.FileReader ??= class {
  readAsArrayBuffer(blob) {
    blob.arrayBuffer().then((buffer) => {
      this.result = buffer;
      this.onloadend?.();
    });
  }
};

const outDir = fileURLToPath(new URL("../../public/library/", import.meta.url));

const std = (color, extra = {}) =>
  new THREE.MeshStandardMaterial({ color, roughness: 0.48, metalness: 0.05, ...extra });

const mesh = (geometry, material, x = 0, y = 0, z = 0) => {
  const m = new THREE.Mesh(geometry, material);
  m.position.set(x, y, z);
  return m;
};

const EXTRUDE = { depth: 0.22, bevelEnabled: true, bevelSize: 0.03, bevelThickness: 0.03, bevelSegments: 2 };

const build = {
  pizza() {
    const slice = new THREE.Shape();
    slice.moveTo(0, -0.62);
    slice.lineTo(0.46, 0.34);
    slice.quadraticCurveTo(0, 0.56, -0.46, 0.34);
    slice.closePath();
    const crust = new THREE.Shape();
    crust.moveTo(0.5, 0.33);
    crust.quadraticCurveTo(0, 0.58, -0.5, 0.33);
    crust.lineTo(-0.5, 0.45);
    crust.quadraticCurveTo(0, 0.72, 0.5, 0.45);
    crust.closePath();
    const bevel = { bevelEnabled: true, bevelSize: 0.02, bevelThickness: 0.02, bevelSegments: 1 };
    const g = new THREE.Group();
    g.add(mesh(new THREE.ExtrudeGeometry(slice, { depth: 0.1, ...bevel }), std(0xf5c542)));
    g.add(mesh(new THREE.ExtrudeGeometry(crust, { depth: 0.16, ...bevel }), std(0xc98a3a), 0, 0, -0.02));
    for (const [x, y] of [[0, 0.22], [-0.17, 0.05], [0.14, -0.02], [0.02, -0.28]]) {
      const pepperoni = mesh(new THREE.CylinderGeometry(0.095, 0.095, 0.03, 18), std(0xc8352b), x, y, 0.13);
      pepperoni.rotation.x = Math.PI / 2;
      g.add(pepperoni);
    }
    return g;
  },

  cup() {
    const g = new THREE.Group();
    g.add(mesh(new THREE.CylinderGeometry(0.42, 0.3, 1, 28), std(0xffffff), 0, 0.5, 0));
    g.add(mesh(new THREE.CylinderGeometry(0.39, 0.39, 0.02, 28), std(0x6b3f22), 0, 0.97, 0));
    g.add(mesh(new THREE.CylinderGeometry(0.385, 0.33, 0.34, 28), std(0x7a4b2a), 0, 0.46, 0));
    g.add(mesh(new THREE.TorusGeometry(0.21, 0.055, 10, 24), std(0xffffff), 0.46, 0.55, 0));
    return g;
  },

  gift() {
    const g = new THREE.Group();
    g.add(mesh(new THREE.BoxGeometry(1, 0.78, 1), std(0x00a5b5), 0, 0.39, 0));
    g.add(mesh(new THREE.BoxGeometry(1.08, 0.18, 1.08), std(0x00b9c9), 0, 0.86, 0));
    g.add(mesh(new THREE.BoxGeometry(0.2, 0.98, 1.1), std(0xffc93c), 0, 0.48, 0));
    g.add(mesh(new THREE.BoxGeometry(1.1, 0.98, 0.2), std(0xffc93c), 0, 0.48, 0));
    const left = mesh(new THREE.TorusGeometry(0.17, 0.05, 10, 22), std(0xffc93c), -0.17, 1.08, 0);
    left.rotation.z = 0.5;
    const right = mesh(new THREE.TorusGeometry(0.17, 0.05, 10, 22), std(0xffc93c), 0.17, 1.08, 0);
    right.rotation.z = -0.5;
    g.add(left, right);
    return g;
  },

  star() {
    const s = new THREE.Shape();
    for (let i = 0; i < 10; i++) {
      const r = i % 2 ? 0.22 : 0.5;
      const a = Math.PI / 2 + (i * Math.PI) / 5;
      if (i) s.lineTo(Math.cos(a) * r, Math.sin(a) * r);
      else s.moveTo(Math.cos(a) * r, Math.sin(a) * r);
    }
    s.closePath();
    const g = new THREE.Group();
    g.add(mesh(new THREE.ExtrudeGeometry(s, EXTRUDE), std(0xf2b705, { metalness: 0.25 })));
    return g;
  },

  heart() {
    const s = new THREE.Shape();
    s.moveTo(0, -0.5);
    s.bezierCurveTo(-0.65, -0.05, -0.55, 0.45, -0.25, 0.45);
    s.bezierCurveTo(-0.1, 0.45, 0, 0.32, 0, 0.22);
    s.bezierCurveTo(0, 0.32, 0.1, 0.45, 0.25, 0.45);
    s.bezierCurveTo(0.55, 0.45, 0.65, -0.05, 0, -0.5);
    const g = new THREE.Group();
    g.add(mesh(new THREE.ExtrudeGeometry(s, EXTRUDE), std(0xe5356f)));
    return g;
  },

  note() {
    const s = new THREE.Shape();
    const w = 0.55, h = 0.36, r = 0.12;
    s.moveTo(-w + r, -h);
    s.lineTo(-0.1, -h);
    s.lineTo(-0.28, -h - 0.22);
    s.lineTo(-0.26, -h);
    s.lineTo(w - r, -h);
    s.quadraticCurveTo(w, -h, w, -h + r);
    s.lineTo(w, h - r);
    s.quadraticCurveTo(w, h, w - r, h);
    s.lineTo(-w + r, h);
    s.quadraticCurveTo(-w, h, -w, h - r);
    s.lineTo(-w, -h + r);
    s.quadraticCurveTo(-w, -h, -w + r, -h);
    const g = new THREE.Group();
    g.add(mesh(new THREE.ExtrudeGeometry(s, EXTRUDE), std(0x2f7fe0)));
    for (const x of [-0.25, 0, 0.25]) g.add(mesh(new THREE.SphereGeometry(0.07, 14, 12), std(0xffffff), x, 0, 0.27));
    return g;
  },
};

/** Scales an object to fit a 1 m box, centred on x and z, sitting on y = 0. */
function normalize(object) {
  const root = new THREE.Group();
  root.add(object);
  root.updateMatrixWorld(true);
  const box = new THREE.Box3().setFromObject(object);
  const size = box.getSize(new THREE.Vector3());
  const centre = box.getCenter(new THREE.Vector3());
  const k = 1 / (Math.max(size.x, size.y, size.z) || 1);
  object.scale.multiplyScalar(k);
  object.position.set(-centre.x * k, -box.min.y * k, -centre.z * k);
  return root;
}

function countTriangles(object) {
  let n = 0;
  object.traverse((node) => {
    if (!node.isMesh) return;
    const g = node.geometry;
    n += (g.index ? g.index.count : g.attributes.position.count) / 3;
  });
  return n;
}

await mkdir(outDir, { recursive: true });
const exporter = new GLTFExporter();

for (const [id, make] of Object.entries(build)) {
  const scene = new THREE.Scene();
  const object = normalize(make());
  object.name = id;
  // Mapbox's model loader needs indexed meshes; extruded shapes come out unindexed.
  object.traverse((node) => {
    if (node.isMesh && !node.geometry.index) node.geometry = mergeVertices(node.geometry);
  });
  scene.add(object);
  const glb = await exporter.parseAsync(scene, { binary: true });
  await writeFile(join(outDir, `${id}.glb`), Buffer.from(glb));
  console.log(`${id}.glb  ${(glb.byteLength / 1024).toFixed(1)} KB  ${countTriangles(object)} triangles`);
}
