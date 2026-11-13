import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { supabaseConfigured, supabaseKey, supabaseUrl } from "./config";

let client: SupabaseClient | null = null;

/** A client with no session, for public reads on the server (drop pages, link previews). */
export function anonClient(): SupabaseClient | null {
  if (!supabaseConfigured) return null;
  client ??= createClient(supabaseUrl, supabaseKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  return client;
}
