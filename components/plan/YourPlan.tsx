"use client";

// Your plan: what the account can add, how much of it is used, and asking for a
// bigger plan. There's no payment yet; Hololoco staff grant plans by hand.

import { useState } from "react";
import { SignIn } from "@/components/auth/SignIn";
import { useSession } from "@/components/auth/session";
import { inputClass, labelClass, primaryButton, textButton } from "@/components/ui";
import { planNames, priceText, requestPlan, withdrawPlanRequest, type Plan, type PlanId } from "@/lib/plans";
import { timeAgo } from "@/lib/review";
import { useMyPlan } from "./useMyPlan";

function features(plan: Plan): string[] {
  return [
    `${plan.maxDrops.toLocaleString("en-US")} drops at a time, ${plan.dailyDrops} new a day`,
    "Messages and objects, with a ready-made look or your photo",
    ...(plan.models ? ["Your own 3D models"] : []),
    ...(plan.offers ? ["Offers: coupons, giveaways and gift cards people redeem at your business", "Offers can join quests with businesses nearby"] : []),
    ...(plan.events ? ["Your own events: hunts and trails across your drops, with bonus XP, points and a reward"] : []),
  ];
}

export function YourPlan() {
  const session = useSession();
  const [version, setVersion] = useState(0);
  const mine = useMyPlan(version);
  const [asking, setAsking] = useState<PlanId | null>(null);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function send(plan: PlanId) {
    setBusy(true);
    setError(null);
    const failed = await requestPlan(plan, note);
    setBusy(false);
    if (failed) return setError(failed);
    setAsking(null);
    setNote("");
    setVersion((v) => v + 1);
  }

  async function withdraw() {
    setBusy(true);
    setError(await withdrawPlanRequest());
    setBusy(false);
    setVersion((v) => v + 1);
  }

  const current = mine?.plans.find((p) => p.id === mine.plan);
  const request = mine?.request ?? null;

  return (
    <>
      <div className="flex flex-col gap-1">
        <h1 className="text-[22px] font-bold">Your plan</h1>
        <p className="text-sm text-muted">
          Messages and pictures are free. Bigger plans add more pins, your own 3D models, offers and events.
        </p>
      </div>

      {session.status === "loading" && <p className="text-sm text-muted">Loading…</p>}
      {session.status === "signed-out" && <SignIn next="/plan" lead="Sign in to see your plan." />}
      {session.status === "signed-in" && mine === undefined && <p className="text-sm text-muted">Loading…</p>}
      {session.status === "signed-in" && mine === null && (
        <p className="rounded-lg bg-wash px-3 py-2.5 text-sm">Plans aren&apos;t switched on here yet.</p>
      )}

      {mine && current && (
        <>
          <div className="flex flex-col gap-1 rounded-lg bg-accent-wash px-3 py-2.5 text-sm">
            <b className="text-base font-semibold">
              {mine.staff ? "Staff: no limits" : `You're on ${current.name}`}
            </b>
            {!mine.staff && (
              <span>
                {mine.drops} of {current.maxDrops} drops used · {mine.dropsToday} of {current.dailyDrops} added today
              </span>
            )}
            {mine.until && <span>Until {new Date(mine.until).toLocaleDateString()}</span>}
          </div>

          {request && (
            <div role="status" className="flex flex-col gap-1 rounded-lg bg-wash px-3 py-2.5 text-sm">
              {request.status === "open" && (
                <>
                  <b className="font-semibold">You asked for {planNames[request.plan]} {timeAgo(request.at)}</b>
                  <span>Hololoco will look at it, usually within a day.</span>
                  <button type="button" disabled={busy} onClick={withdraw} className={`${textButton} self-start`}>
                    Withdraw the request
                  </button>
                </>
              )}
              {request.status === "granted" && <b className="font-semibold">You&apos;re on {planNames[request.plan]} now.</b>}
              {request.status === "declined" && (
                <b className="font-semibold">Hololoco didn&apos;t give you {planNames[request.plan]} this time.</b>
              )}
              {request.answer && request.status !== "open" && <span>{request.answer}</span>}
            </div>
          )}

          {error && (
            <p role="alert" className="text-sm text-rejected">
              {error}
            </p>
          )}

          <ul className="flex flex-col gap-3">
            {mine.plans.map((plan) => {
              const isCurrent = plan.id === mine.plan;
              const higher = plan.id !== "free" && mine.plans.indexOf(plan) > mine.plans.indexOf(current);
              const open = request?.status === "open" && request.plan === plan.id;
              return (
                <li
                  key={plan.id}
                  className={`flex flex-col gap-2 rounded-lg border p-3 ${isCurrent ? "border-accent" : "border-line"}`}
                >
                  <div className="flex flex-wrap items-baseline justify-between gap-x-3">
                    <h2 className="text-base font-semibold">
                      {plan.name}
                      {isCurrent && <span className="ml-2 text-[13px] font-medium text-accent">Your plan</span>}
                    </h2>
                    <span className="text-[13px] text-muted">{priceText(plan)}</span>
                  </div>
                  <p className="text-sm">{plan.blurb}</p>
                  <ul className="flex list-disc flex-col gap-0.5 pl-5 text-[13px] text-muted">
                    {features(plan).map((f) => (
                      <li key={f}>{f}</li>
                    ))}
                  </ul>
                  {higher && !mine.staff && !open && asking !== plan.id && (
                    <button
                      type="button"
                      onClick={() => {
                        setAsking(plan.id);
                        setError(null);
                      }}
                      className={`${textButton} self-start`}
                    >
                      Ask for {plan.name}
                    </button>
                  )}
                  {asking === plan.id && (
                    <form
                      className="flex flex-col gap-2"
                      onSubmit={(event) => {
                        event.preventDefault();
                        void send(plan.id);
                      }}
                    >
                      <label className={labelClass}>
                        What will you use it for?
                        <textarea
                          value={note}
                          maxLength={500}
                          rows={3}
                          required
                          placeholder={plan.offers ? "Your business's name and address, and what you'd offer." : "What you'd like to post."}
                          onChange={(event) => setNote(event.target.value)}
                          className={`${inputClass} py-2 leading-normal`}
                        />
                      </label>
                      <div className="flex gap-2">
                        <button type="submit" disabled={busy || !note.trim()} className={`${primaryButton} flex-1`}>
                          {busy ? "Sending…" : `Ask for ${plan.name}`}
                        </button>
                        <button type="button" onClick={() => setAsking(null)} className={textButton}>
                          Cancel
                        </button>
                      </div>
                    </form>
                  )}
                </li>
              );
            })}
          </ul>
        </>
      )}
    </>
  );
}
