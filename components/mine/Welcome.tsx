import Link from "next/link";
import { SignIn } from "@/components/auth/SignIn";
import { SheetHeight } from "@/components/map/SheetHeight";

/** The start page before signing in: what the website is for, and the way in. */
export function Welcome() {
  return (
    <>
      <SheetHeight size="full" />
      <div className="flex flex-col gap-2">
        <h1 className="text-[26px] leading-tight font-bold">Put your business on the map</h1>
        <p className="leading-normal text-muted">
          Place offers, 3D objects and messages right where your business is. People will find them in the Hololoco
          app.
        </p>
      </div>

      <SignIn next="/" lead="Sign in, or create an account. There's no password to remember." />

      <p className="mt-auto text-[13px] text-muted">
        Want something taken off your property?{" "}
        <Link href="/report" className="font-medium text-accent hover:underline">
          Tell us
        </Link>
        . No account needed.
      </p>
    </>
  );
}
