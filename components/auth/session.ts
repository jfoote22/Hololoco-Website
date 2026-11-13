"use client";

// Who is signed in, for the browser. Pages read it with useSession(); it updates
// when someone signs in or out in this tab or another one. This is only for what
// the screen shows: the database checks the session itself on every call.

import type { User } from "@supabase/supabase-js";
import { useSyncExternalStore } from "react";
import { supabaseConfigured } from "@/lib/supabase/config";
import { browserClient } from "@/lib/supabase/browser";

export type Session =
  | { status: "loading" }
  | { status: "signed-out" }
  | { status: "signed-in"; user: { id: string; email: string | null; suggestedName: string | null } };

const LOADING: Session = { status: "loading" };
const SIGNED_OUT: Session = { status: "signed-out" };

let current: Session = supabaseConfigured ? LOADING : SIGNED_OUT;
let started = false;
const listeners = new Set<() => void>();

function set(next: Session) {
  current = next;
  for (const listener of listeners) listener();
}

function fromUser(user: User | null | undefined): Session {
  if (!user) return SIGNED_OUT;
  const meta = user.user_metadata ?? {};
  const name = typeof meta.full_name === "string" ? meta.full_name : typeof meta.name === "string" ? meta.name : null;
  return { status: "signed-in", user: { id: user.id, email: user.email ?? null, suggestedName: name } };
}

function start() {
  if (started) return;
  started = true;
  const client = browserClient();
  if (!client) return set(SIGNED_OUT);
  client.auth.getSession().then(({ data }) => set(fromUser(data.session?.user)));
  // Only set state here: calling Supabase inside this callback can deadlock it.
  client.auth.onAuthStateChange((_event, session) => set(fromUser(session?.user)));
}

function subscribe(listener: () => void) {
  start();
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export function useSession(): Session {
  return useSyncExternalStore(
    subscribe,
    () => current,
    () => LOADING,
  );
}

export async function signOut(): Promise<void> {
  await browserClient()?.auth.signOut();
}
