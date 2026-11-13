"use client";

import { useEffect } from "react";
import { useMap, type SheetSize } from "./MapProvider";

/** Sets the height the phone sheet opens at for the current screen. Renders nothing. */
export function SheetHeight({ size }: { size: SheetSize }) {
  const { setSheet } = useMap();
  useEffect(() => {
    setSheet(size);
  }, [size, setSheet]);
  return null;
}
