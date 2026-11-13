// Processed uploads wait in this browser (IndexedDB) until Publish, so they
// survive signing in with a link that reloads the page. Falls back to memory
// when the browser won't store them (some private windows).

import type { ProcessedUpload } from "./types";

const DB_NAME = "hololoco";
const STORE = "uploads";
const memory = new Map<string, ProcessedUpload>();

function open(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    if (typeof indexedDB === "undefined") return reject(new Error("No IndexedDB"));
    const request = indexedDB.open(DB_NAME, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(STORE);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function run<T>(mode: IDBTransactionMode, action: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const db = await open();
  try {
    return await new Promise<T>((resolve, reject) => {
      const request = action(db.transaction(STORE, mode).objectStore(STORE));
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
  } finally {
    db.close();
  }
}

export async function keepUpload(id: string, upload: ProcessedUpload): Promise<void> {
  memory.set(id, upload);
  try {
    await run("readwrite", (store) => store.put(upload, id));
  } catch {
    // Memory only: it lasts until the page closes.
  }
}

export async function findUpload(id: string): Promise<ProcessedUpload | null> {
  const kept = memory.get(id);
  if (kept) return kept;
  try {
    return ((await run("readonly", (store) => store.get(id))) as ProcessedUpload | undefined) ?? null;
  } catch {
    return null;
  }
}

export async function forgetUpload(id: string): Promise<void> {
  memory.delete(id);
  try {
    await run("readwrite", (store) => store.delete(id));
  } catch {
    // Nothing kept.
  }
}
