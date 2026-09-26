import type pg from "pg";
import { meteredRoutes, type MeteredRoute, type MeteringOutcome } from "./event.js";

/**
 * Reading the metering table from a terminal: `npm run usage` (SONNY-133) is a command over the
 * functions below, not a surface a user sees.
 *
 * **Nothing here is a price.** The columns it sums are tokens, bytes and milliseconds. Reported and
 * estimated tokens are summed apart and never added, because §4.2's `usage.source` exists so a
 * summary can say which numbers a provider measured.
 */

/** How much of the table a query looks at. Every field optional; nothing here is required. */
export interface UsageWindow {
  readonly accountId?: string;
  readonly sessionId?: string;
  readonly taskId?: string;
  /** Inclusive lower bound on `occurred_at`. */
  readonly since?: Date;
  /** Exclusive upper bound on `occurred_at`. */
  readonly until?: Date;
}

/**
 * The window as a SQL fragment and its bind values.
 *
 * Every value is a parameter — none is interpolated — so a session id read off a terminal cannot
 * become SQL. The fragment always starts with a true predicate, so a caller can concatenate without
 * caring whether anything was added.
 */
function windowClause(
  window: UsageWindow,
  startingAt = 1,
): { readonly sql: string; readonly values: unknown[] } {
  const clauses: string[] = [];
  const values: unknown[] = [];
  const bind = (value: unknown): string => {
    values.push(value);
    return `$${startingAt + values.length - 1}`;
  };
  if (window.accountId !== undefined) clauses.push(`account_id = ${bind(window.accountId)}`);
  if (window.sessionId !== undefined) clauses.push(`session_id = ${bind(window.sessionId)}`);
  if (window.taskId !== undefined) clauses.push(`task_id = ${bind(window.taskId)}`);
  if (window.since !== undefined) clauses.push(`occurred_at >= ${bind(window.since)}`);
  if (window.until !== undefined) clauses.push(`occurred_at < ${bind(window.until)}`);
  return { sql: clauses.length === 0 ? "true" : clauses.join(" AND "), values };
}

/**
 * `bigint` and `numeric` come back from `pg` as strings, because they can exceed a JS number. Every
 * sum below is over values this gateway wrote and stays well inside one. Converted here so a caller
 * adding two of these gets arithmetic instead of concatenation.
 */
function count(value: string | number | null | undefined): number {
  if (value === null || value === undefined) return 0;
  return typeof value === "number" ? value : Number(value);
}

function tally(values: readonly string[]): Readonly<Partial<Record<MeteringOutcome, number>>> {
  const counts: Partial<Record<MeteringOutcome, number>> = {};
  for (const value of values) {
    const outcome = value as MeteringOutcome;
    counts[outcome] = (counts[outcome] ?? 0) + 1;
  }
  return counts;
}

/** What one route cost across the window. */
export interface RouteTotals {
  readonly route: MeteredRoute;
  readonly calls: number;
  readonly reportedTotalTokens: number;
  readonly estimatedTotalTokens: number;
  readonly callsWithoutTokens: number;
  readonly audioSeconds: number;
  readonly upstreamMs: number;
  readonly outcomes: Readonly<Partial<Record<MeteringOutcome, number>>>;
}

interface RouteRow {
  /** Any route the table's CHECK allows, including ones only older rows carry. */
  route: string;
  calls: string | number;
  reported_total_tokens: string | number | null;
  estimated_total_tokens: string | number | null;
  calls_without_tokens: string | number;
  audio_seconds: string | number | null;
  upstream_ms: string | number | null;
  outcomes: string[];
}

/**
 * Every metered route's totals across the window, in `meteredRoutes` order. Rows under a route this
 * gateway no longer meters are not reported.
 */
export async function routeTotals(
  client: pg.Client,
  window: UsageWindow = {},
): Promise<readonly RouteTotals[]> {
  const scope = windowClause(window);
  const { rows } = await client.query<RouteRow>(
    `SELECT route,
            count(*)                                                       AS calls,
            coalesce(sum(total_tokens) FILTER (WHERE token_source = 'reported'), 0)  AS reported_total_tokens,
            coalesce(sum(total_tokens) FILTER (WHERE token_source = 'estimated'), 0) AS estimated_total_tokens,
            count(*) FILTER (WHERE token_source IS NULL)                   AS calls_without_tokens,
            coalesce(sum(audio_duration_seconds), 0)                       AS audio_seconds,
            coalesce(sum(upstream_duration_ms), 0)                         AS upstream_ms,
            array_agg(outcome)                                             AS outcomes
       FROM sonny.metering_event
      WHERE ${scope.sql}
      GROUP BY route`,
    scope.values,
  );

  const byRoute = new Map(rows.map((row) => [row.route, row]));
  return meteredRoutes
    .filter((route) => byRoute.has(route))
    .map((route) => {
      const row = byRoute.get(route)!;
      return {
        route,
        calls: count(row.calls),
        reportedTotalTokens: count(row.reported_total_tokens),
        estimatedTotalTokens: count(row.estimated_total_tokens),
        callsWithoutTokens: count(row.calls_without_tokens),
        audioSeconds: count(row.audio_seconds),
        upstreamMs: count(row.upstream_ms),
        outcomes: tally(row.outcomes),
      };
    });
}

/**
 * The oldest event still in the table, and how many there are. Nothing in this gateway deletes or
 * ages a metering row, and this is how an operator can see that for themselves.
 */
export async function meteringSpan(
  client: pg.Client,
  window: UsageWindow = {},
): Promise<{ readonly events: number; readonly oldest: Date | null; readonly newest: Date | null }> {
  const scope = windowClause(window);
  const { rows } = await client.query<{
    events: string | number;
    oldest: Date | null;
    newest: Date | null;
  }>(
    `SELECT count(*) AS events, min(occurred_at) AS oldest, max(occurred_at) AS newest
       FROM sonny.metering_event
      WHERE ${scope.sql}`,
    scope.values,
  );
  const row = rows[0];
  return {
    events: count(row?.events),
    oldest: row?.oldest ?? null,
    newest: row?.newest ?? null,
  };
}
