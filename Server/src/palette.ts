// A surface's colors on the web, matching Palette in the app (Dream/UI/Theme.swift): the ink,
// a neighbouring hue for the glow and a second series, and quiet tints for panels. The inks are
// tuned for each appearance: deep enough to read on white, bright enough on black.

const SYSTEM: Record<string, [light: string, dark: string]> = {
  blue: ["#2563EB", "#5B8CFF"],
  teal: ["#0F9488", "#2DD4BF"],
  green: ["#0E9F6E", "#34D399"],
  mint: ["#0EA5A0", "#5EEAD4"],
  orange: ["#E8670C", "#FF8A3D"],
  pink: ["#DB2777", "#FF6B9A"],
  purple: ["#9333EA", "#C084FC"],
  indigo: ["#4F46E5", "#8B83FF"],
  red: ["#DC2626", "#FF5A5A"],
  yellow: ["#B7791F", "#FBBF24"],
  cyan: ["#0891B2", "#38D5F5"],
  brown: ["#9A5B2E", "#D19A66"],
};

/** A neighbouring hue, so gradients shift a little without turning into a rainbow. */
const COMPANION: Record<string, string> = {
  blue: "cyan",
  teal: "blue",
  green: "teal",
  mint: "cyan",
  orange: "pink",
  pink: "orange",
  purple: "indigo",
  indigo: "blue",
  red: "orange",
  yellow: "orange",
  cyan: "blue",
  brown: "orange",
};

export function accentOf(raw: unknown): string {
  return typeof raw === "string" && raw in SYSTEM ? raw : "blue";
}

/** CSS custom properties for one accent, light and dark. */
export function paletteCSS(accent: string): string {
  const [light, dark] = SYSTEM[accent];
  const [companionLight, companionDark] = SYSTEM[COMPANION[accent]];
  return `:root{--accent:${light};--companion:${companionLight}}
@media (prefers-color-scheme: dark){:root{--accent:${dark};--companion:${companionDark}}}`;
}

/** The accent for `theme-color`, so the browser's bar takes the surface's color. */
export function themeColor(accent: string): string {
  return SYSTEM[accent][0];
}
