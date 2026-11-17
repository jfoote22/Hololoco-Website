import type { Metadata, Viewport } from "next";
import { DM_Sans, Outfit, Plus_Jakarta_Sans } from "next/font/google";
import Script from "next/script";
import { MapProvider } from "@/components/map/MapProvider";
import { MapView } from "@/components/MapView";
import { Panel } from "@/components/Panel";
import { SKIN_SCRIPT } from "@/lib/skin";
import "./globals.css";

const dmSans = DM_Sans({ variable: "--font-dm-sans", subsets: ["latin"] });
const outfit = Outfit({ variable: "--font-outfit", subsets: ["latin"] });
// Soft night's typeface; Daylight uses DM Sans and Outfit.
const jakarta = Plus_Jakarta_Sans({ variable: "--font-jakarta", subsets: ["latin"] });

export const metadata: Metadata = {
  title: { default: "Hololoco", template: "%s · Hololoco" },
  description:
    "Put your business on the Hololoco map: place offers, 3D objects and messages at your location for people to find in the Hololoco app.",
};

export const viewport: Viewport = {
  themeColor: "#ffffff",
};

// The map fills the screen and stays mounted across routes, and every screen is
// the one floating panel on top of it.
export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    // Browser extensions (like Scribe) add attributes to <html> before React loads.
    // This ignores those on this one tag only; everything inside is still checked.
    <html lang="en" className={`${dmSans.variable} ${outfit.variable} ${jakarta.variable} antialiased`} suppressHydrationWarning>
      <body className="overflow-hidden">
        {/* The saved look (Daylight or Soft night), applied before anything draws. */}
        <Script id="hl-skin" strategy="beforeInteractive">
          {SKIN_SCRIPT}
        </Script>
        <MapProvider>
          <MapView />
          <Panel>{children}</Panel>
        </MapProvider>
      </body>
    </html>
  );
}
