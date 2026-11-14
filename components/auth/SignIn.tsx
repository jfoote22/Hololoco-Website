"use client";

// Sign in with an email or with Google. The email holds a code to type here and a
// link; the code keeps people in this tab with their draft, which matters on phones
// where mail apps open links in another browser.

import { useState } from "react";
import { browserClient } from "@/lib/supabase/browser";
import { NEXT_COOKIE } from "./next";

const googleOn = process.env.NEXT_PUBLIC_GOOGLE_SIGN_IN === "on";

function rememberNext(next: string) {
  document.cookie = `${NEXT_COOKIE}=${encodeURIComponent(next)}; path=/; max-age=3600; samesite=lax`;
}

function returnUrl(next: string) {
  return `${window.location.origin}/auth/confirm?next=${encodeURIComponent(next)}`;
}

function sendErrorText(error: { code?: string; message?: string }): string {
  if (error.code === "email_address_not_authorized")
    return "Sign-in emails can only go to the Hololoco team for now. Try Google, or ask the team.";
  if (error.code === "over_email_send_rate_limit" || error.code === "over_request_rate_limit")
    return "Too many sign-in emails just now. Wait a few minutes and try again.";
  if (error.code === "email_address_invalid" || error.code === "validation_failed")
    return "That email address doesn't look right.";
  return "Couldn't send the email. Try again in a moment.";
}

export function SignIn({ next, lead }: { next: string; lead?: string }) {
  const [email, setEmail] = useState("");
  const [sentTo, setSentTo] = useState<string | null>(null);
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const client = browserClient();

  if (!client) {
    return <p className="rounded-lg bg-wash px-3 py-2.5 text-sm text-muted">Signing in isn&apos;t switched on here yet.</p>;
  }

  async function send(event: React.FormEvent) {
    event.preventDefault();
    if (!client) return;
    setBusy(true);
    setError(null);
    rememberNext(next);
    const address = email.trim();
    const { error } = await client.auth.signInWithOtp({
      email: address,
      options: { emailRedirectTo: returnUrl(next) },
    });
    setBusy(false);
    if (error) setError(sendErrorText(error));
    else setSentTo(address);
  }

  async function verify(event: React.FormEvent) {
    event.preventDefault();
    if (!client || !sentTo) return;
    setBusy(true);
    setError(null);
    const { error } = await client.auth.verifyOtp({ email: sentTo, token: code.replace(/\s/g, ""), type: "email" });
    setBusy(false);
    // On success the session changes and whoever showed this form moves on.
    if (error) setError("That code didn't work. Check it, or send a new email.");
  }

  async function google() {
    if (!client) return;
    setError(null);
    rememberNext(next);
    const { error } = await client.auth.signInWithOAuth({ provider: "google", options: { redirectTo: returnUrl(next) } });
    if (error) setError("Couldn't start Google sign-in. Try the email instead.");
  }

  return (
    <div className="flex flex-col gap-3">
      {lead && <p className="text-sm">{lead}</p>}

      {googleOn && !sentTo && (
        <>
          <button
            type="button"
            onClick={google}
            className="flex min-h-11 items-center justify-center gap-2 rounded-lg border border-line px-4 font-semibold hover:bg-wash"
          >
            <svg width="18" height="18" viewBox="0 0 48 48" aria-hidden="true">
              <path fill="#4285F4" d="M45.1 24.5c0-1.6-.1-3.1-.4-4.5H24v8.5h11.8c-.5 2.8-2.1 5.1-4.4 6.7v5.6h7.1c4.2-3.8 6.6-9.5 6.6-16.3z" />
              <path fill="#34A853" d="M24 46c5.9 0 10.9-2 14.5-5.3l-7.1-5.6c-2 1.3-4.5 2.1-7.4 2.1-5.7 0-10.5-3.8-12.2-9H4.5v5.8C8.1 41.1 15.5 46 24 46z" />
              <path fill="#FBBC05" d="M11.8 28.2c-.4-1.3-.7-2.7-.7-4.2s.3-2.9.7-4.2V14H4.5C3 17 2 20.4 2 24s1 7 2.5 10l7.3-5.8z" />
              <path fill="#EA4335" d="M24 10.8c3.2 0 6.1 1.1 8.4 3.3l6.3-6.3C34.9 4.2 29.9 2 24 2 15.5 2 8.1 6.9 4.5 14l7.3 5.8c1.7-5.2 6.5-9 12.2-9z" />
            </svg>
            Continue with Google
          </button>
          <p className="text-center text-[13px] text-muted">or use your email</p>
        </>
      )}

      {sentTo ? (
        <form onSubmit={verify} className="flex flex-col gap-2">
          <p className="text-sm">
            We sent an email to <b className="break-all">{sentTo}</b>. Type the code from it here, or open its link on
            this device.
          </p>
          <label className="flex flex-col gap-1 text-sm font-medium">
            Code from the email
            <input
              inputMode="numeric"
              autoComplete="one-time-code"
              pattern="[0-9 ]{6,12}"
              required
              value={code}
              onChange={(event) => setCode(event.target.value)}
              className="min-h-11 rounded-lg border border-line px-3 text-base tracking-widest outline-none focus:border-accent"
            />
          </label>
          <button
            type="submit"
            disabled={busy}
            className="min-h-11 rounded-lg bg-accent px-4 font-semibold text-white hover:bg-accent-strong disabled:opacity-60"
          >
            {busy ? "Checking…" : "Sign in"}
          </button>
          <button
            type="button"
            onClick={() => {
              setSentTo(null);
              setCode("");
              setError(null);
            }}
            className="min-h-11 self-start px-1 text-sm font-medium text-accent hover:underline"
          >
            Use a different email
          </button>
        </form>
      ) : (
        <form onSubmit={send} className="flex flex-col gap-2">
          <label className="flex flex-col gap-1 text-sm font-medium">
            Email
            <input
              type="email"
              autoComplete="email"
              required
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              className="min-h-11 rounded-lg border border-line px-3 text-base outline-none focus:border-accent"
            />
          </label>
          <button
            type="submit"
            disabled={busy}
            className="min-h-11 rounded-lg bg-accent px-4 font-semibold text-white hover:bg-accent-strong disabled:opacity-60"
          >
            {busy ? "Sending…" : "Email me a sign-in code"}
          </button>
        </form>
      )}

      {error && (
        <p role="alert" className="text-sm text-rejected">
          {error}
        </p>
      )}
    </div>
  );
}
