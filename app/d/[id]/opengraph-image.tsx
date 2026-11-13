import { readFileSync } from "node:fs";
import { join } from "node:path";
import { ImageResponse } from "next/og";
import { bylineLong, photoFor, thumbnailFor, timingText } from "@/lib/drops/format";
import { getDrop } from "@/lib/drops/page";

// The link preview for a drop: its object, title and who posted it.

export const alt = "A drop on the Hololoco map";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

const ink = "#17242c";
const muted = "#5a6b75";
const accent = "#006d7a";

export default async function Image({ params }: { params: Promise<{ id: string }> }) {
  const drop = await getDrop((await params).id);
  const picture = drop ? await pictureFor(photoFor(drop) ?? thumbnailFor(drop)) : null;
  const when = drop ? timingText(drop.timing) : null;

  return new ImageResponse(
    (
      <div style={{ width: "100%", height: "100%", display: "flex", alignItems: "center", gap: 64, padding: 72, background: "#f2f5f7", color: ink }}>
        <div style={{ width: 420, height: 420, flexShrink: 0, display: "flex", alignItems: "center", justifyContent: "center", borderRadius: 36, background: "#ffffff", boxShadow: "0 12px 40px rgba(23,36,44,0.12)" }}>
          {/* ImageResponse draws plain <img>; next/image doesn't apply here. */}
          {/* eslint-disable-next-line @next/next/no-img-element */}
          {picture && <img src={picture} width={320} height={320} alt="" />}
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 22, flex: 1 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 14, fontSize: 34, fontWeight: 700, color: ink }}>
            <svg width="30" height="41" viewBox="0 0 22 30">
              <circle cx="11" cy="11" r="8.5" fill="none" stroke={accent} strokeWidth="4" />
              <rect x="10" y="20" width="2" height="9" fill={accent} />
            </svg>
            hololoco
          </div>
          <div style={{ fontSize: 64, fontWeight: 700, lineHeight: 1.08, letterSpacing: -1 }}>{drop?.title ?? "Drop not found"}</div>
          {drop && <div style={{ fontSize: 32, color: muted }}>{bylineLong(drop)}</div>}
          {when && <div style={{ fontSize: 28, color: muted }}>{when}</div>}
        </div>
      </div>
    ),
    size,
  );
}

/** The picture as a data URL: a ready-made thumbnail from disk, or an upload from storage. */
async function pictureFor(src: string | null): Promise<string | null> {
  if (!src) return null;
  try {
    if (src.startsWith("/")) return `data:image/png;base64,${readFileSync(join(process.cwd(), "public", src)).toString("base64")}`;
    const response = await fetch(src);
    if (!response.ok) return null;
    const type = response.headers.get("content-type") ?? "image/png";
    return `data:${type};base64,${Buffer.from(await response.arrayBuffer()).toString("base64")}`;
  } catch {
    return null;
  }
}
