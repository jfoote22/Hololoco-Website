"use client";

import { useEffect } from "react";
import { useMap, type PanelWidth as Width } from "./MapProvider";

/** Sets how wide the desktop panel is while this screen is open. Renders nothing. */
export function PanelWidth({ width }: { width: Width }) {
  const { setPanelWidth } = useMap();
  useEffect(() => {
    setPanelWidth(width);
    return () => setPanelWidth("normal");
  }, [width, setPanelWidth]);
  return null;
}
