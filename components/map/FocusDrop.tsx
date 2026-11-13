"use client";

import { useEffect } from "react";
import type { PublicDrop } from "@/lib/drops/types";
import { useMap } from "./MapProvider";

/** While a drop's page is open, the map flies to it and highlights its pin. Renders nothing. */
export function FocusDrop({ drop }: { drop: PublicDrop }) {
  const { focus } = useMap();
  useEffect(() => {
    focus(drop);
    return () => focus(null);
  }, [drop, focus]);
  return null;
}
