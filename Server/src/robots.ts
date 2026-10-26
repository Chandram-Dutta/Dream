// robots.txt, as RFC 9309 reads it: the group for Dream's reader if a site names it, otherwise the
// group for every crawler; the longest matching rule decides, and Allow wins a tie.
//
// No imports, so `npm test` checks these directly in Node.

/** The reader's product token, which sites name in robots.txt to set rules for it. */
export const READER_TOKEN = "DreamReader";

interface Rule {
  allow: boolean;
  pattern: string;
}

/** Whether robots.txt lets `agent` read `path` (the path and query of a URL). */
export function robotsAllows(robots: string, path: string, agent = READER_TOKEN): boolean {
  const rules = rulesFor(robots, agent.toLowerCase());
  let best: Rule | undefined;
  for (const rule of rules) {
    // An empty Disallow allows everything; an empty Allow says nothing.
    if (!rule.pattern || !matches(rule.pattern, path)) continue;
    if (!best || rule.pattern.length > best.pattern.length || (rule.pattern.length === best.pattern.length && rule.allow && !best.allow)) best = rule;
  }
  return best?.allow ?? true;
}

/** The rules that apply to an agent: every group naming it, or else every group for `*`. */
function rulesFor(robots: string, agent: string): Rule[] {
  const named: Rule[] = [];
  const everyone: Rule[] = [];
  let agents: string[] = [];
  let inRules = false;
  for (const raw of robots.slice(0, 500_000).split(/\r\n|\r|\n/)) {
    const line = raw.replace(/#.*$/, "").trim();
    const colon = line.indexOf(":");
    if (colon < 1) continue;
    const field = line.slice(0, colon).trim().toLowerCase();
    const value = line.slice(colon + 1).trim();
    if (field === "user-agent") {
      // A user-agent line after rules starts a new group.
      if (inRules) agents = [];
      inRules = false;
      agents.push(value.toLowerCase());
    } else if (field === "allow" || field === "disallow") {
      inRules = true;
      const rule = { allow: field === "allow", pattern: value };
      if (agents.some((name) => name && name !== "*" && agent.includes(name))) named.push(rule);
      if (agents.includes("*")) everyone.push(rule);
    }
  }
  return named.length ? named : everyone;
}

/** A robots.txt path pattern: a prefix, where `*` is any run of characters and a final `$` anchors the end. */
function matches(pattern: string, path: string): boolean {
  const anchored = pattern.endsWith("$");
  const body = anchored ? pattern.slice(0, -1) : pattern;
  const expression = body.split("*").map((piece) => piece.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*");
  return new RegExp(`^${expression}${anchored ? "$" : ""}`).test(path);
}
