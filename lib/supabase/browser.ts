import { createBrowserClient } from "@supabase/ssr";
import type { SupabaseClient } from "@supabase/supabase-js";
import { supabaseConfigured, supabaseKey, supabaseUrl } from "./config";

let client: SupabaseClient | null = null;

/** The browser's client. It keeps the person's session in cookies. Null on the server or when not set up. */
export function browserClient(): SupabaseClient | null {
  if (!supabaseConfigured || typeof window === "undefined") return null;
  if (!client) {
    client = createBrowserClient(supabaseUrl, supabaseKey);
    // For driving the app from a test browser during development only.
    if (process.env.NODE_ENV === "development") Object.assign(window, { __hlSupabase: client });
  }
  return client;
}
