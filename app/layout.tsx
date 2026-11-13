import type { Metadata, Viewport } from "next";
import { DM_Sans, Outfit } from "next/font/google";
import { MapView } from "@/components/MapView";
import { Panel } from "@/components/Panel";
import "./globals.css";

const dmSans = DM_Sans({ variable: "--font-dm-sans", subsets: ["latin"] });
const outfit = Outfit({ variable: "--font-outfit", subsets: ["latin"] });

export const metadata: Metadata = {
  title: { default: "Hololoco", template: "%s · Hololoco" },
  description:
    "An open 3D map of the real world. Place an object, an offer or a message at a real location, and find what others left nearby.",
};

export const viewport: Viewport = {
  themeColor: "#ffffff",
};

// The map is the product: it fills the screen and stays mounted across routes,
// and every screen is the one floating panel on top of it.
export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en" className={`${dmSans.variable} ${outfit.variable} antialiased`}>
      <body className="overflow-hidden">
        <MapView />
        <Panel>{children}</Panel>
      </body>
    </html>
  );
}
