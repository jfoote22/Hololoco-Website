// Scales a whole GLB by changing only its JSON chunk. The binary chunk (geometry
// and textures, nearly all of the file) streams through untouched, so a large
// model passes through without being held in memory.

const MAGIC = 0x46546c67; // "glTF"
const JSON_CHUNK = 0x4e4f534a; // "JSON"

type Gltf = { scene?: number; scenes?: { nodes?: number[] }[]; nodes?: object[] };

/** Puts the default scene under one node scaled by `factor`, and drops any other scenes. */
export function scaleScene(json: Gltf, factor: number): void {
  const scene = json.scenes?.[json.scene ?? 0];
  if (!scene) throw new Error("The model has no scene.");
  json.nodes ??= [];
  const root = json.nodes.push({ name: "TrueSize", scale: [factor, factor, factor], children: scene.nodes ?? [] }) - 1;
  json.scenes = [{ ...scene, nodes: [root] }];
  json.scene = 0;
}

/** The GLB read from `source`, with everything scaled by `factor`. */
export async function scaledGlb(source: ReadableStream<Uint8Array>, factor: number): Promise<ReadableStream<Uint8Array>> {
  const reader = source.getReader();
  let head = new Uint8Array(0);
  // Reads until at least `bytes` have arrived. Only the small header and JSON are gathered.
  const gather = async (bytes: number) => {
    while (head.length < bytes) {
      const { done, value } = await reader.read();
      if (done) throw new Error("The model file ended early.");
      const joined = new Uint8Array(head.length + value.length);
      joined.set(head);
      joined.set(value, head.length);
      head = joined;
    }
  };

  try {
    await gather(20);
    const view = new DataView(head.buffer, head.byteOffset, 20);
    if (view.getUint32(0, true) !== MAGIC || view.getUint32(4, true) !== 2 || view.getUint32(16, true) !== JSON_CHUNK)
      throw new Error("That isn't a glTF 2.0 binary file.");
    const jsonLength = view.getUint32(12, true);
    await gather(20 + jsonLength);

    const json = JSON.parse(new TextDecoder().decode(head.subarray(20, 20 + jsonLength))) as Gltf;
    scaleScene(json, factor);
    const text = new TextEncoder().encode(JSON.stringify(json));
    const padded = Math.ceil(text.length / 4) * 4;

    const start = new Uint8Array(20 + padded);
    const out = new DataView(start.buffer);
    out.setUint32(0, MAGIC, true);
    out.setUint32(4, 2, true);
    out.setUint32(8, view.getUint32(8, true) - jsonLength + padded, true);
    out.setUint32(12, padded, true);
    out.setUint32(16, JSON_CHUNK, true);
    start.set(text, 20);
    start.fill(0x20, 20 + text.length); // JSON chunks are padded with spaces.
    const rest = head.subarray(20 + jsonLength);

    return new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(start);
        if (rest.length) controller.enqueue(rest);
      },
      async pull(controller) {
        const { done, value } = await reader.read();
        if (done) controller.close();
        else controller.enqueue(value);
      },
      cancel: (reason) => reader.cancel(reason),
    });
  } catch (error) {
    await reader.cancel().catch(() => {});
    throw error;
  }
}
