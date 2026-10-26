// A surface's colors on the web, matching Palette in the app (Dream/UI/Theme.swift): the
// accent, a neighbouring hue for gradients, and quiet tints for panels. Colors are iOS's system
// colors, in light and dark.

const SYSTEM: Record<string, [light: string, dark: string]> = {
  blue: ["#0088FF", "#0091FF"],
  teal: ["#00C3D0", "#00D2E0"],
  green: ["#34C759", "#30D158"],
  mint: ["#00C8B3", "#00DAC3"],
  orange: ["#FF8D28", "#FF9230"],
  pink: ["#FF2D55", "#FF375F"],
  purple: ["#CB30E0", "#DB34F2"],
  indigo: ["#6155F5", "#6D7CFF"],
  red: ["#FF383C", "#FF4245"],
  yellow: ["#FFCC00", "#FFD600"],
  cyan: ["#00C0E8", "#3CD3FE"],
  brown: ["#AC7F5E", "#B78A66"],
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
