import type { Metadata } from "next";
import { Orbitron, Inter } from "next/font/google";
import { Providers } from "./providers";
import "./globals.css";

const orbitron = Orbitron({ subsets: ["latin"], weight: ["600", "700", "800", "900"], variable: "--font-display" });
const inter = Inter({ subsets: ["latin"], weight: ["400", "500", "600"], variable: "--font-body" });

export const metadata: Metadata = {
  title: "DomainBound — one key, one door",
  description: "A signature cut for one vault. Watch it fit one lock and bounce off the other.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${orbitron.variable} ${inter.variable}`}>
      <body><Providers>{children}</Providers></body>
    </html>
  );
}
