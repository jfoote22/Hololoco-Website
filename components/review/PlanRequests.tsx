"use client";

// Staff: people asking for a bigger plan. Until there are payments, granting one
// here is what changes an account's plan.

import { useEffect, useState } from "react";
import { useSession } from "@/components/auth/session";
import { inputClass, textButton } from "@/components/ui";
import { decidePlanRequest, listPlanRequests, planNames, type QueuedPlanRequest } from "@/lib/plans";
import { timeAgo } from "@/lib/review";

export function PlanRequests() {
  const session = useSession();
  const userId = session.status === "signed-in" ? session.user.id : null;
  const [loaded, setLoaded] = useState<{ userId: string; requests: QueuedPlanRequest[] | null } | null>(null);
  const [answers, setAnswers] = useState<Record<number, string>>({});
  const [busy, setBusy] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!userId) return;
    let cancelled = false;
    listPlanRequests()
      .then((requests) => !cancelled && setLoaded({ userId, requests }))
      // Not staff, or no plans in this database: show nothing.
      .catch(() => !cancelled && setLoaded({ userId, requests: null }));
    return () => {
      cancelled = true;
    };
  }, [userId]);

  const requests = loaded?.userId === userId ? loaded.requests : null;
  if (!requests) return null;

  async function decide(request: QueuedPlanRequest, grant: boolean) {
    setBusy(request.id);
    setError(null);
    const failed = await decidePlanRequest(request.id, grant, answers[request.id] ?? "");
    setBusy(null);
    if (failed) return setError(failed);
    setLoaded((l) => (l?.requests ? { ...l, requests: l.requests.filter((r) => r.id !== request.id) } : l));
  }

  return (
    <section className="flex flex-col gap-2 border-t border-line pt-3" aria-labelledby="plan-requests-heading">
      <h2 id="plan-requests-heading" className="text-base font-semibold">
        {requests.length === 0 ? "No plan requests" : `Plan requests (${requests.length})`}
      </h2>
      {error && (
        <p role="alert" className="text-sm text-rejected">
          {error}
        </p>
      )}
      <ul className="flex flex-col divide-y divide-line">
        {requests.map((request) => (
          <li key={request.id} className="flex flex-col gap-1.5 py-3 text-sm">
            <span>
              <b className="font-semibold">{request.user.name}</b> asks for <b className="font-semibold">{planNames[request.plan]}</b>{" "}
              <span className="text-muted">{timeAgo(request.at)}</span>
            </span>
            <span className="text-[13px] text-muted">
              {request.user.email ?? "No email"} · on {planNames[request.user.plan]} · {request.user.drops} drops · joined{" "}
              {timeAgo(request.user.since)}
              {request.user.strikes > 0 ? ` · ${request.user.strikes} strike${request.user.strikes === 1 ? "" : "s"}` : ""}
            </span>
            <p className="rounded-lg bg-wash px-3 py-2 break-words whitespace-pre-line">{request.note}</p>
            <input
              value={answers[request.id] ?? ""}
              maxLength={500}
              placeholder="A note for them (optional)"
              aria-label={`A note for ${request.user.name}`}
              onChange={(event) => setAnswers((a) => ({ ...a, [request.id]: event.target.value }))}
              className={inputClass}
            />
            <div className="flex flex-wrap gap-x-3">
              <button type="button" disabled={busy === request.id} onClick={() => decide(request, true)} className={textButton}>
                Give them {planNames[request.plan]}
              </button>
              <button type="button" disabled={busy === request.id} onClick={() => decide(request, false)} className={`${textButton} text-muted`}>
                Decline
              </button>
            </div>
          </li>
        ))}
      </ul>
    </section>
  );
}
