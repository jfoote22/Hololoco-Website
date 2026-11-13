// Renders a PNG thumbnail for each GLB in public/library/ using headless Chrome,
// so pins, lists and link previews show exactly the object that goes on the map.
//
// Run after build-models.mjs: node scripts/library/render-thumbnails.mjs
// Set CHROME_PATH if Chrome isn't in the usual place.

import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { readdir, readFile, stat } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, normalize, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const run = promisify(execFile);
const root = fileURLToPath(new URL("../../", import.meta.url));
const libraryDir = join(root, "public", "library");
const SIZE = 256;

const chrome =
  process.env.CHROME_PATH ??
  [
    "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
    "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
  ].find((p) => existsSync(p));

if (!chrome) throw new Error("Chrome not found. Set CHROME_PATH.");

const types = { ".html": "text/html", ".js": "text/javascript", ".glb": "model/gltf-binary" };

// Serves the repository folder on localhost only, for the page and three.js.
const server = createServer(async (req, res) => {
  const path = normalize(join(root, decodeURIComponent(new URL(req.url, "http://x").pathname)));
  if (!path.startsWith(root.endsWith(sep) ? root : root + sep)) return res.writeHead(403).end();
  try {
    if (!(await stat(path)).isFile()) throw new Error();
    res.writeHead(200, { "content-type": types[extname(path)] ?? "application/octet-stream" });
    res.end(await readFile(path));
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const port = server.address().port;

const ids = (await readdir(libraryDir)).filter((f) => f.endsWith(".glb")).map((f) => f.slice(0, -4));

try {
  for (const id of ids) {
    const out = join(libraryDir, `${id}.png`);
    await run(chrome, [
      "--headless=new",
      "--use-angle=swiftshader",
      "--enable-unsafe-swiftshader",
      "--hide-scrollbars",
      "--default-background-color=00000000",
      `--window-size=${SIZE},${SIZE}`,
      "--virtual-time-budget=15000",
      `--screenshot=${out}`,
      `http://127.0.0.1:${port}/scripts/library/thumbnail.html?id=${id}&size=${SIZE}`,
    ]);
    console.log(`${id}.png  ${((await stat(out)).size / 1024).toFixed(1)} KB`);
  }
} finally {
  server.close();
}
