// Hololoco's own Supabase project. Both values are public by design: what anyone
// can read or change is decided by the database's rules (supabase/migrations/),
// not by keeping these hidden. Without them the site runs on sample drops only.

export const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
export const supabaseKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? "";
export const supabaseConfigured = supabaseUrl !== "" && supabaseKey !== "";
