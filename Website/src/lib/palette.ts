// Every Dream page has its own colors: an accent and a neighbouring hue (Dream/UI/Theme.swift,
// Server/src/palette.ts). These are iOS's system colors, in light and dark. Anything marked
// `data-accent` takes them as --accent and --companion; the page itself starts in the colors of
// the time of day, as the app's home screen does.

export type Accent = "blue" | "teal" | "green" | "mint" | "orange" | "pink" | "purple" | "indigo" | "red" | "cyan";

export const SYSTEM: Record<Accent, [light: string, dark: string]> = {
  blue: ["#0088FF", "#0091FF"],
  teal: ["#00C3D0", "#00D2E0"],
  green: ["#34C759", "#30D158"],
  mint: ["#00C8B3", "#00DAC3"],
  orange: ["#FF8D28", "#FF9230"],
  pink: ["#FF2D55", "#FF375F"],
  purple: ["#CB30E0", "#DB34F2"],
  indigo: ["#6155F5", "#6D7CFF"],
  red: ["#FF383C", "#FF4245"],
  cyan: ["#00C0E8", "#3CD3FE"],
};

/** A neighbouring hue, so gradients shift a little without turning into a rainbow. */
export const COMPANION: Record<Accent, Accent> = {
  blue: "cyan",
  teal: "blue",
  green: "teal",
  mint: "cyan",
  orange: "pink",
  pink: "orange",
  purple: "indigo",
  indigo: "blue",
  red: "orange",
  cyan: "blue",
};

/** A hue on the accent's other side, for the site's Aura only: three neighbouring hues give the
 * full-screen field more depth than two, still without a rainbow. */
export const THIRD: Record<Accent, Accent> = {
  blue: "indigo",
  teal: "mint",
  green: "mint",
  mint: "green",
  orange: "red",
  pink: "purple",
  purple: "pink",
  indigo: "purple",
  red: "pink",
  cyan: "teal",
};

/** Palette.now in Theme.swift: mint in the morning, blue by day, orange in the evening, indigo at night. */
export function accentAt(hour: number): Accent {
  return hour >= 5 && hour < 11 ? "mint" : hour >= 11 && hour < 17 ? "blue" : hour >= 17 && hour < 21 ? "orange" : "indigo";
}

/** The colors for every accent, as CSS, in both themes. */
export function paletteCSS(): string {
  const light: string[] = [];
  const dark: string[] = [];
  for (const accent of Object.keys(SYSTEM) as Accent[]) {
    const companion = COMPANION[accent];
    light.push(`[data-accent="${accent}"]{--accent:${SYSTEM[accent][0]};--companion:${SYSTEM[companion][0]}}`);
    dark.push(`[data-accent="${accent}"]{--accent:${SYSTEM[accent][1]};--companion:${SYSTEM[companion][1]}}`);
  }
  return `${light.join("\n")}\n@media (prefers-color-scheme: dark){\n${dark.join("\n")}\n}`;
}
