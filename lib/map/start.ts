// Where the map opens when there's no drop to show: downtown Austin, the likely first
// launch city. It's centred on the Lady Bird Lake shore at the South First Street bridge,
// looking east-northeast at the skyline. The sample drops are placed around it.

import type { View } from "./engine";

export const START_VIEW = {
  center: { lat: 30.26342, lng: -97.747158 },
  zoom: 16.7,
  pitch: 64.5,
  bearing: 61.3,
} satisfies View;
