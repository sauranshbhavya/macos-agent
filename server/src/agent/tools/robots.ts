/**
 * robots.txt as RFC 9309 reads it, for the page reader. Sonny doesn't read a page a site asks
 * automated tools not to read: the product spec says Sonny must not bypass robots restrictions.
 *
 * A group that names Sonny replaces the `*` group rather than adding to it (RFC 9309 §2.2.1), the
 * longest matching rule wins with Allow winning a tie, and `*` and a closing `$` are wildcards
 * (§2.2.3). Patterns are matched without regular expressions, because a site writes them.
 */

/** The product tokens a robots.txt group can name Sonny by. The reader sends `SonnyResearch/2`. */
export const ROBOTS_PRODUCT_TOKENS: readonly string[] = ["sonny", "sonnyresearch"];

export interface RobotsRule {
  readonly allow: boolean;
  readonly pattern: string;
}

export type RobotsRules = readonly RobotsRule[];

export const ALLOW_ALL: RobotsRules = [];
export const DISALLOW_ALL: RobotsRules = [{ allow: false, pattern: "/" }];

/** Longer patterns are cut here, and rules past the limit are dropped, so a site can't make one check expensive. */
const PATTERN_LIMIT = 2_000;
const RULE_LIMIT = 2_000;
/**
 * The most character comparisons one check may make. A check that would need more is answered
 * "disallowed", so a hostile file and a very long address can't hold up the gateway.
 */
const MATCH_BUDGET = 2_000_000;

export function parseRobots(text: string, tokens: readonly string[] = ROBOTS_PRODUCT_TOKENS): RobotsRules {
  const named: RobotsRule[] = [];
  const anyone: RobotsRule[] = [];
  let sawNamedGroup = false;
  let groupNamesUs = false;
  let groupIsAnyone = false;
  let groupHasRules = false;
  for (const raw of text.split(/\r\n|\r|\n/)) {
    const line = raw.replace(/#.*$/, "").trim();
    const colon = line.indexOf(":");
    if (colon < 0) continue;
    const key = line.slice(0, colon).trim().toLowerCase();
    const value = line.slice(colon + 1).trim();
    if (key === "user-agent") {
      // A user-agent line after a rule starts a new group; consecutive ones share a group.
      if (groupHasRules) {
        groupNamesUs = false;
        groupIsAnyone = false;
        groupHasRules = false;
      }
      const agent = (value.split("/")[0] ?? "").trim().toLowerCase();
      if (agent === "*") {
        groupIsAnyone = true;
      } else if (tokens.includes(agent)) {
        groupNamesUs = true;
        sawNamedGroup = true;
      }
    } else if (key === "allow" || key === "disallow") {
      groupHasRules = true;
      // An empty Disallow allows everything, which is what no rule already means.
      if (value === "") continue;
      const rule = { allow: key === "allow", pattern: value.slice(0, PATTERN_LIMIT) };
      if (groupNamesUs && named.length < RULE_LIMIT) named.push(rule);
      if (groupIsAnyone && anyone.length < RULE_LIMIT) anyone.push(rule);
    }
  }
  return sawNamedGroup ? named : anyone;
}

export function robotsAllow(rules: RobotsRules, url: URL): boolean {
  if (url.pathname === "/robots.txt") return true;
  const target = url.pathname + url.search;
  const budget = { left: MATCH_BUDGET };
  let best: RobotsRule | undefined;
  for (const rule of rules) {
    const matched = patternMatches(rule.pattern, target, budget);
    if (budget.left < 0) return false;
    if (!matched) continue;
    if (
      best === undefined ||
      rule.pattern.length > best.pattern.length ||
      (rule.pattern.length === best.pattern.length && rule.allow && !best.allow)
    ) {
      best = rule;
    }
  }
  return best?.allow ?? true;
}

/**
 * Whether `target` starts with `pattern`, where `*` stands for any run of characters and a closing
 * `$` means the target ends there. A greedy match with one backtrack point: at most pattern length
 * times target length steps, however many `*`s there are, and fewer than `budget.left`: the match
 * stops once that runs out.
 */
export function patternMatches(pattern: string, target: string, budget: { left: number } = { left: Infinity }): boolean {
  const anchored = pattern.endsWith("$");
  const glob = anchored ? pattern.slice(0, -1) : `${pattern}*`;
  let t = 0;
  let p = 0;
  let star = -1;
  let resume = 0;
  while (t < target.length) {
    budget.left -= 1;
    if (budget.left < 0) return false;
    if (p < glob.length && glob[p] !== "*" && glob[p] === target[t]) {
      t += 1;
      p += 1;
    } else if (p < glob.length && glob[p] === "*") {
      star = p;
      p += 1;
      resume = t;
    } else if (star >= 0) {
      p = star + 1;
      resume += 1;
      t = resume;
    } else {
      return false;
    }
  }
  while (p < glob.length && glob[p] === "*") p += 1;
  return p === glob.length;
}
