/** Remembers where to go after a sign-in link is opened in this browser. */
export const NEXT_COOKIE = "hl-next";

/** Only paths on this site, so a sign-in link can't be used to send someone elsewhere. */
export function safeNext(value: string | null | undefined): string {
  if (!value) return "/";
  let path = value;
  try {
    path = decodeURIComponent(value);
  } catch {
    return "/";
  }
  return path.startsWith("/") && !path.startsWith("//") && !path.startsWith("/\\") ? path : "/";
}
