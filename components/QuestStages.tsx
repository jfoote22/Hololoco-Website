import { rarityLabel } from "@/lib/drops/format";
import { legText, openHoursText, type Quest } from "@/lib/quests";

/** A quest's stages in order, with who offers each and when they're all open. */
export function QuestStages({ quest, highlight }: { quest: Quest; highlight?: string }) {
  return (
    <div className="flex flex-col gap-1.5 rounded-lg bg-wash px-3 py-2 text-[13px]">
      <ol className="flex flex-col gap-1">
        {quest.stages.map((stage) => (
          <li key={stage.position} className="flex gap-2">
            <span className="w-14 shrink-0 font-semibold">Stage {stage.position}</span>
            <span className="min-w-0">
              {stage.drop ? (
                <>
                  <span className={stage.drop.id === highlight ? "font-semibold" : undefined}>
                    {stage.drop.offer?.savings ?? stage.drop.title}
                  </span>
                  <span className="text-muted">
                    {" "}
                    · {stage.drop.owner.name} · {rarityLabel[stage.rarity]}
                  </span>
                </>
              ) : (
                <span className="text-muted">No longer available</span>
              )}
            </span>
          </li>
        ))}
      </ol>
      <p className="text-muted">
        Open together: {openHoursText(quest.openHours)}. {legText(quest.maxLegMetres)}.
      </p>
    </div>
  );
}
