"use client";

// "View in AR": the drop at its true size through the phone's camera, in the
// phone's own AR viewer, with no app to install. Android opens Google's Scene
// Viewer with the drop's model; iPhones and iPads need USDZ, which is made here
// in the browser from the same model. Other devices don't get the button.

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { secondaryButton } from "@/components/ui";

type Viewer = "quick-look" | "scene-viewer" | null;

const subscribeToNothing = () => () => {};

function phoneViewer(): Viewer {
  try {
    if (document.createElement("a").relList.supports("ar")) return "quick-look";
  } catch {
    // Older browsers throw when asked about link types.
  }
  return /android/i.test(navigator.userAgent) ? "scene-viewer" : null;
}

// Scene Viewer sends people back to the page with this mark when it can't open.
const NO_AR = "#no-ar";
const subscribeToHash = (onChange: () => void) => {
  window.addEventListener("hashchange", onChange);
  return () => window.removeEventListener("hashchange", onChange);
};

function sceneViewerLink(id: string, title: string): string {
  const site = window.location.origin;
  const query = `file=${encodeURIComponent(`${site}/d/${id}/model.glb`)}&mode=ar_preferred&title=${encodeURIComponent(title)}`;
  const fallback = encodeURIComponent(`${site}/d/${id}${NO_AR}`);
  return `intent://arvr.google.com/scene-viewer/1.0?${query}#Intent;scheme=https;package=com.google.android.googlequicksearchbox;action=android.intent.action.VIEW;S.browser_fallback_url=${fallback};end;`;
}

async function makeUsdz(id: string): Promise<string> {
  const [{ GLTFLoader }, { USDZExporter }] = await Promise.all([
    import("three/addons/loaders/GLTFLoader.js"),
    import("three/addons/exporters/USDZExporter.js"),
  ]);
  const gltf = await new GLTFLoader().loadAsync(`/d/${id}/model.glb`);
  const usdz = await new USDZExporter().parseAsync(gltf.scene, { quickLookCompatible: true });
  return URL.createObjectURL(new Blob([usdz as Uint8Array<ArrayBuffer>], { type: "model/vnd.usdz+zip" }));
}

export function ViewInAr({ id, title }: { id: string; title: string }) {
  const viewer = useSyncExternalStore(subscribeToNothing, phoneViewer, () => null);
  const sentBack = useSyncExternalStore(subscribeToHash, () => window.location.hash === NO_AR, () => false);
  const [state, setState] = useState<"idle" | "preparing" | "failed">("idle");
  // Kept so a second look opens at once.
  const usdz = useRef<{ id: string; url: string } | null>(null);
  useEffect(
    () => () => {
      if (usdz.current) URL.revokeObjectURL(usdz.current.url);
    },
    [],
  );

  async function openQuickLook() {
    setState("preparing");
    try {
      if (usdz.current?.id !== id) {
        if (usdz.current) URL.revokeObjectURL(usdz.current.url);
        usdz.current = { id, url: await makeUsdz(id) };
      }
      // Quick Look opens from a link marked rel="ar" with an image inside.
      const link = document.createElement("a");
      link.rel = "ar";
      link.href = usdz.current.url;
      link.download = "model.usdz";
      link.style.display = "none";
      link.append(document.createElement("img"));
      document.body.append(link);
      link.click();
      link.remove();
      setState("idle");
    } catch (error) {
      console.warn("Couldn't prepare the model for AR:", error);
      setState("failed");
    }
  }

  if (!viewer) return null;

  const label = (
    <>
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <path d="M12 3l8 4.5v9L12 21l-8-4.5v-9zM12 12l8-4.5M12 12v9M12 12L4 7.5" />
      </svg>
      {state === "preparing" ? "Getting it ready…" : "View in AR"}
    </>
  );

  return (
    <div className="flex flex-col gap-1.5">
      {viewer === "scene-viewer" ? (
        <a href={sceneViewerLink(id, title)} className={secondaryButton}>
          {label}
        </a>
      ) : (
        <button type="button" onClick={openQuickLook} disabled={state === "preparing"} className={secondaryButton}>
          {label}
        </button>
      )}
      {(sentBack || state === "failed") && (
        <p role="status" className="text-[13px] text-muted">
          {state === "failed"
            ? "Couldn't get it ready for AR. Try again."
            : "AR didn't open on this phone. It needs the Google app and Google Play Services for AR, both free in the Play Store."}
        </p>
      )}
    </div>
  );
}
