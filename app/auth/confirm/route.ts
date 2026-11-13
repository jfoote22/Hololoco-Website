import type { EmailOtpType } from "@supabase/supabase-js";
import { cookies } from "next/headers";
import { NextResponse, type NextRequest } from "next/server";
import { NEXT_COOKIE, safeNext } from "@/components/auth/next";
import { serverClient } from "@/lib/supabase/server";

// Where sign-in links land: the link in the sign-in email, and the return from
// Google. It turns the one-time token into a session cookie, then sends the person
// back to what they were doing (their draft is still saved in the browser).

export async function GET(request: NextRequest) {
  const params = request.nextUrl.searchParams;
  const jar = await cookies();
  const next = safeNext(params.get("next") ?? jar.get(NEXT_COOKIE)?.value);
  jar.delete(NEXT_COOKIE);

  const supabase = await serverClient();
  const code = params.get("code");
  const tokenHash = params.get("token_hash");
  const type = params.get("type") as EmailOtpType | null;

  let ok = false;
  if (supabase && code) {
    ok = !(await supabase.auth.exchangeCodeForSession(code)).error;
  } else if (supabase && tokenHash && type) {
    ok = !(await supabase.auth.verifyOtp({ type, token_hash: tokenHash })).error;
  }

  // The redirect drops the one-time token from the address.
  const to = new URL(ok ? next : "/mine?signin=failed", request.nextUrl.origin);
  return NextResponse.redirect(to);
}
