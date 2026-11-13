import type { Metadata } from "next";
import { ComingSoon } from "@/components/ComingSoon";

export const metadata: Metadata = { title: "Add to the map" };

const steps = [
  ["What", "Choose Object, Message or Offer, write a title, then pick a look."],
  ["Where", "Search or tap to place it, then set its size, height and turn."],
  ["When and who", "Always and Everyone by default, so most people just press Publish."],
] as const;

export default function AddScreen() {
  return (
    <ComingSoon title="Add to the map" purpose="Three steps, and you never leave the map." phase="Phase 2">
      <ol className="flex flex-col gap-2">
        {steps.map(([name, line], i) => (
          <li key={name} className="flex gap-3 rounded-lg border border-line p-3">
            <span className="grid size-6 shrink-0 place-items-center rounded-full bg-accent-wash text-xs font-bold text-accent">
              {i + 1}
            </span>
            <span className="text-sm">
              <b className="block">{name}</b>
              <span className="text-muted">{line}</span>
            </span>
          </li>
        ))}
      </ol>
    </ComingSoon>
  );
}
