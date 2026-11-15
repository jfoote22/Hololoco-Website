"use client";

// Draws one quest's route on the map and fits the map to it. The route goes when
// the screen showing it does.

import { useCallback, useEffect } from "react";
import { boundsOf, routeOf, type Quest } from "@/lib/quests";
import { useMap } from "./MapProvider";

export function useQuestRoute() {
  const { engine, setSheet } = useMap();

  useEffect(() => () => engine?.setRoute(null), [engine]);

  return useCallback(
    (quest: Quest | null) => {
      if (!engine) return;
      if (!quest) return engine.setRoute(null);
      const points = routeOf(quest);
      engine.setRoute(points);
      // Lower the phone sheet first: changing the map's padding afterwards would
      // cancel the move, so fit once the new padding is in place.
      setSheet("peek");
      const bounds = boundsOf(points);
      if (bounds) setTimeout(() => engine.fitBounds(bounds, { maxZoom: 16.5 }), 80);
    },
    [engine, setSheet],
  );
}
