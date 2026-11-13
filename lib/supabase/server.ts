import "server-only";
import { createServerClient } from "@supabase/ssr";
import type { SupabaseClient } from "@supabase/supabase-js";
import { cookies } from "next/headers";
import { supabaseConfigured, supabaseKey, supabaseUrl } from "./config";

/** A client acting as the person whose session cookies came with this request. */
export async function serverClient(): Promise<SupabaseClient | null> {
  if (!supabaseConfigured) return null;
  const cookieStore = await cookies();
  return createServerClient(supabaseUrl, supabaseKey, {
    cookies: {
      getAll: () => cookieStore.getAll(),
      setAll(cookiesToSet) {
        try {
          for (const { name, value, options } of cookiesToSet) cookieStore.set(name, value, options);
        } catch {
          // Called while rendering a Server Component, where cookies can't be set.
          // The browser client refreshes the session itself.
        }
      },
    },
  });
}
