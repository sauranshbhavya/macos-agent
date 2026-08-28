import type pg from "pg";
import { meteredRoutes, type MeteredRoute, type MeteringOutcome } from "./event.js";

/**
 * Reading the metering table — the founders' own pre-launch measurement (SONNY-133).
 *
 * **This is the query path the ticket asks for, and it is deliberately not a surface.** The
 * coordinator settled it on 2026-08-28: the usage UI is SONNY-214's, and what this ticket owes is a
 * way to answer "what did screen control cost me across these sessions" from a terminal. So it is a
 * command — `npm run usage` — over the functions below, and nothing here renders anything a user
 * sees.
 *
 * **Nothing here is a price, and nothing here may become one.** The columns it sums are tokens,
 * bytes, pixels, iterations and milliseconds. SONNY-17 turns those into a credit weight and a paid
 * line; a rate, a multiplier or a currency in this file would be that ticket's decision taken by
 * accident in another.
 *
 * **Two figures are reported apart and never added: reported and estimated tokens.** §4.2's
 * `usage.source` exists so a summary can say which of its numbers a provider measured, and summing
 * the two would erase exactly that. On `screen.analyze` it matters most, because that route reports
 * **neither**: `model/vision.ts` sends no estimate at all, since the dominant term is an image whose
 * cost is a function of pixel dimensions and a provider's tiling rule. `pixels` below is what prices
 * that route, and `tokensAreAbsent` is how a caller can see that a zero is an absence rather than a
 * measurement of zero.
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
 * One screen-control session's total cost — the figure SONNY-17's credit weight is derived from.
 *
 * A session is up to twelve iterations (`VisionSessionLimits.default.maximumIterations`), each its
 * own request, its own upstream call and its own row. This is the sum over the rows sharing one
 * `session_id`, which is the whole reason §4.5 puts that field on the wire.
 */
export interface ScreenControlSessionCost {
  readonly sessionId: string;
  readonly accountId: string;
  /** The tasks this session's iterations belonged to. Normally one; more would be a client bug. */
  readonly taskIds: readonly string[];
  readonly iterations: number;
  /** The highest `session_iteration` any row carries, so a gap in the sequence is visible. */
  readonly highestIteration: number | null;
  readonly firstAt: Date;
  readonly lastAt: Date;
  readonly reportedInputTokens: number;
  readonly reportedOutputTokens: number;
  readonly reportedTotalTokens: number;
  readonly estimatedTotalTokens: number;
  /**
   * How many of this session's iterations carry no token count at all.
   *
   * **The number that stops a zero being read as a measurement.** `screen.analyze` reports no tokens
   * whenever the provider reported none, and estimates nothing — so a session whose every row is
   * absent sums to zero tokens while having cost a great deal, and `pixels` is what prices it.
   */
  readonly iterationsWithoutTokens: number;
  readonly imageBytes: number;
  /** Total pixels sent, summed per iteration. What vision token cost actually tracks (§4.5 rule 3). */
  readonly pixels: number;
  readonly upstreamMs: number;
  readonly wallMs: number;
  /** Every outcome this session's rows carry, with how many of each. */
  readonly outcomes: Readonly<Partial<Record<MeteringOutcome, number>>>;
  readonly providers: readonly string[];
  /** `none` if any iteration ran with "Don't save this task" on. §10.1: metered either way. */
  readonly retentions: readonly string[];
}

interface SessionRow {
  session_id: string;
  account_id: string;
  task_ids: string[];
  iterations: string | number;
  highest_iteration: string | number | null;
  first_at: Date;
  last_at: Date;
  reported_input_tokens: string | number | null;
  reported_output_tokens: string | number | null;
  reported_total_tokens: string | number | null;
  estimated_total_tokens: string | number | null;
  iterations_without_tokens: string | number;
  image_bytes: string | number | null;
  pixels: string | number | null;
  upstream_ms: string | number | null;
  wall_ms: string | number | null;
  outcomes: string[];
  providers: string[];
  retentions: string[];
}

/**
 * `bigint` and `numeric` come back from `pg` as strings, because they can exceed a JS number.
 *
 * Every sum below is over integers this gateway wrote, so none of them can — a session is twelve
 * iterations. Converted here rather than left as strings, so a caller adding two of these gets
 * arithmetic instead of concatenation, which is the one way this could go quietly wrong.
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

/**
 * Every screen-control session in the window, newest first, with what each one cost.
 *
 * **Only `route = 'screen.analyze'` rows are read**, and that is not an optimisation: `session_id`
 * is absent on the other four routes by contract (§2.4), so a row from one of them could not join a
 * session even if the column were somehow set. Restricting it here means a client bug that put a
 * session id on a `/v1/plan` request cannot inflate a screen-control figure.
 *
 * The reported and estimated sums are `FILTER`ed on `token_source` rather than being one sum,
 * because §4.2's distinction between a number a provider measured and one this server derived is the
 * whole point of that field.
 */
export async function screenControlSessionCosts(
  client: pg.Client,
  window: UsageWindow = {},
): Promise<readonly ScreenControlSessionCost[]> {
  const scope = windowClause(window);
  const { rows } = await client.query<SessionRow>(
    `SELECT session_id,
            min(account_id::text)                                          AS account_id,
            array_remove(array_agg(DISTINCT task_id), NULL)                AS task_ids,
            count(*)                                                       AS iterations,
            max(session_iteration)                                         AS highest_iteration,
            min(occurred_at)                                               AS first_at,
            max(occurred_at)                                               AS last_at,
            coalesce(sum(input_tokens)  FILTER (WHERE token_source = 'reported'), 0)  AS reported_input_tokens,
            coalesce(sum(output_tokens) FILTER (WHERE token_source = 'reported'), 0)  AS reported_output_tokens,
            coalesce(sum(total_tokens)  FILTER (WHERE token_source = 'reported'), 0)  AS reported_total_tokens,
            coalesce(sum(total_tokens)  FILTER (WHERE token_source = 'estimated'), 0) AS estimated_total_tokens,
            count(*) FILTER (WHERE token_source IS NULL)                   AS iterations_without_tokens,
            coalesce(sum(image_bytes), 0)                                  AS image_bytes,
            coalesce(sum(image_pixel_width::bigint * image_pixel_height), 0) AS pixels,
            coalesce(sum(upstream_duration_ms), 0)                         AS upstream_ms,
            coalesce(sum(duration_ms), 0)                                  AS wall_ms,
            array_agg(outcome)                                             AS outcomes,
            array_remove(array_agg(DISTINCT provider), NULL)               AS providers,
            array_remove(array_agg(DISTINCT retention), NULL)              AS retentions
       FROM sonny.metering_event
      WHERE route = 'screen.analyze'
        AND session_id IS NOT NULL
        AND ${scope.sql}
      GROUP BY session_id
      ORDER BY max(occurred_at) DESC`,
    scope.values,
  );

  return rows.map((row) => ({
    sessionId: row.session_id,
    accountId: row.account_id,
    taskIds: row.task_ids,
    iterations: count(row.iterations),
    highestIteration: row.highest_iteration === null ? null : count(row.highest_iteration),
    firstAt: row.first_at,
    lastAt: row.last_at,
    reportedInputTokens: count(row.reported_input_tokens),
    reportedOutputTokens: count(row.reported_output_tokens),
    reportedTotalTokens: count(row.reported_total_tokens),
    estimatedTotalTokens: count(row.estimated_total_tokens),
    iterationsWithoutTokens: count(row.iterations_without_tokens),
    imageBytes: count(row.image_bytes),
    pixels: count(row.pixels),
    upstreamMs: count(row.upstream_ms),
    wallMs: count(row.wall_ms),
    outcomes: tally(row.outcomes),
    providers: row.providers,
    retentions: row.retentions,
  }));
}

/** What one route cost across the window. The wider view the per-session one sits inside. */
export interface RouteTotals {
  readonly route: MeteredRoute;
  readonly calls: number;
  readonly reportedTotalTokens: number;
  readonly estimatedTotalTokens: number;
  readonly callsWithoutTokens: number;
  readonly imageBytes: number;
  readonly audioSeconds: number;
  readonly upstreamMs: number;
  readonly outcomes: Readonly<Partial<Record<MeteringOutcome, number>>>;
}

interface RouteRow {
  route: MeteredRoute;
  calls: string | number;
  reported_total_tokens: string | number | null;
  estimated_total_tokens: string | number | null;
  calls_without_tokens: string | number;
  image_bytes: string | number | null;
  audio_seconds: string | number | null;
  upstream_ms: string | number | null;
  outcomes: string[];
}

/**
 * Every route's totals across the window, in §11's own route order.
 *
 * Ordered by the enum rather than by the data so the shape of the output does not change with which
 * routes happen to have been used, which is what makes two runs comparable by eye.
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
            coalesce(sum(image_bytes), 0)                                  AS image_bytes,
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
        imageBytes: count(row.image_bytes),
        audioSeconds: count(row.audio_seconds),
        upstreamMs: count(row.upstream_ms),
        outcomes: tally(row.outcomes),
      };
    });
}

/**
 * The oldest event still in the table, and how many there are.
 *
 * **This is how "usage outlives content" is checked from outside** (§10.3's two clocks). Content
 * lives 30 days on the short clock; nothing in this gateway deletes or ages a metering row, and this
 * is what lets an operator see that for themselves rather than take a comment's word for it. It is
 * also what `theUsageClockIsNotTheContentClock` asserts against a back-dated row.
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
