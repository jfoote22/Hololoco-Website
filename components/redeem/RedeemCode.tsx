"use client";

// At the counter: the player taps Redeem in the Hololoco app and shows a 6-digit
// code; the business types it in here. Confirming is what redeems the offer, so a
// screenshot of a coupon is worth nothing.

import { useEffect, useState } from "react";
import { SignIn } from "@/components/auth/SignIn";
import { useSession } from "@/components/auth/session";
import { inputClass, labelClass, primaryButton } from "@/components/ui";
import { confirmRedemption, recentRedemptions, type Redeemed, type Redemption } from "@/lib/redeem";
import { timeAgo } from "@/lib/review";

export function RedeemCode() {
  const session = useSession();
  const userId = session.status === "signed-in" ? session.user.id : null;
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<Redeemed | { error: string } | null>(null);
  const [recent, setRecent] = useState<{ userId: string; list: Redemption[] } | null>(null);
  const [version, setVersion] = useState(0);

  useEffect(() => {
    if (!userId) return;
    let cancelled = false;
    recentRedemptions().then((list) => !cancelled && setRecent({ userId, list }));
    return () => {
      cancelled = true;
    };
  }, [userId, version]);

  async function confirm() {
    setBusy(true);
    setResult(null);
    const answer = await confirmRedemption(code);
    setBusy(false);
    setResult(answer);
    if (!("error" in answer)) {
      setCode("");
      setVersion((v) => v + 1);
    }
  }

  const list = recent?.userId === userId ? recent.list : null;

  return (
    <>
      <div className="flex flex-col gap-1">
        <h1 className="text-[22px] font-bold">Redeem a code</h1>
        <p className="text-sm text-muted">
          When someone redeems one of your offers, the Hololoco app shows them a 6-digit code for 10 minutes. Type it in
          here to confirm it. Each code works once.
        </p>
      </div>

      {session.status === "loading" && <p className="text-sm text-muted">Loading…</p>}
      {session.status === "signed-out" && <SignIn next="/redeem" lead="Sign in with your business account." />}

      {userId && (
        <>
          <form
            className="flex flex-col gap-3"
            onSubmit={(event) => {
              event.preventDefault();
              void confirm();
            }}
          >
            <label className={labelClass}>
              Their code
              <input
                value={code}
                inputMode="numeric"
                autoComplete="one-time-code"
                maxLength={7}
                placeholder="123 456"
                onChange={(event) => setCode(event.target.value)}
                className={`${inputClass} text-center font-mono text-2xl tracking-[0.3em]`}
              />
            </label>
            <button type="submit" disabled={busy || code.replace(/\D/g, "").length !== 6} className={primaryButton}>
              {busy ? "Checking…" : "Confirm"}
            </button>
          </form>

          {result && "error" in result && (
            <p role="alert" className="rounded-lg bg-wash px-3 py-2.5 text-sm text-rejected">
              {result.error}
            </p>
          )}
          {result && !("error" in result) && (
            <div role="status" className="flex flex-col gap-1 rounded-lg bg-accent-wash px-3 py-2.5 text-sm">
              <b className="text-base font-semibold text-good">Redeemed</b>
              <span className="font-semibold">{result.savings ?? result.title}</span>
              {result.savings && <span>{result.title}</span>}
              {result.terms && <span className="text-muted">Terms: {result.terms}</span>}
              <span className="text-muted">For {result.player}</span>
            </div>
          )}

          <section className="flex flex-col gap-2 border-t border-line pt-3" aria-labelledby="recent-heading">
            <h2 id="recent-heading" className="text-base font-semibold">
              Redeemed in the last 30 days
            </h2>
            {list === null && <p className="text-sm text-muted">Loading…</p>}
            {list?.length === 0 && <p className="text-sm text-muted">Nothing yet.</p>}
            {list && list.length > 0 && (
              <ul className="flex flex-col divide-y divide-line">
                {list.map((r, i) => (
                  <li key={`${r.at}-${i}`} className="flex flex-col py-2 text-sm">
                    <span className="font-medium">{r.savings ?? r.title}</span>
                    <span className="text-[13px] text-muted">
                      {r.player} · {timeAgo(r.at)}
                    </span>
                  </li>
                ))}
              </ul>
            )}
          </section>
        </>
      )}
    </>
  );
}
