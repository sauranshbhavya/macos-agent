import type pg from "pg";

/**
 * What a founder answering a support question may read, and the record of having read it
 * (SONNY-134). Contract §10, requirement 9.
 *
 * **The access decision is this ticket's and is written down rather than left to whoever has
 * database access** — which is requirement 9's own wording, and the reason this file exists at all
 * rather than the answer being "run psql". Founder decision, 2026-08-28:
 *
 * - **Account state and recent usage are read freely.** Whether someone is signed in, whether their
 *   account is closed, whether they consented to training, what they have been calling and how it
 *   has been going. None of it is content, and a support question that cannot reach it is a support
 *   question nobody can answer.
 * - **Content is reached only through `contentForRequest`, which the CLI refuses to call without an
 *   operator and a reason, and which writes a `sonny.content_access` row before printing.**
 *
 * **It is a discipline and a trace, not a boundary, and saying otherwise would be the actual
 * failure.** Everyone who can run this command also holds `DATABASE_URL`, and `psql` reads the same
 * bytes leaving nothing behind. What this buys today is that a lookup made through the product
 * leaves a record; what it buys later is that the control already exists on the day a support
 * surface is something other than a founder's terminal.
 *
 * **Every query here names its columns.** §10.2's checkable claim that `training_consent` never
 * leaves the server rests on there being no star-select anywhere under `server/src`, and this file
 * is the one most tempted by one.
 *
 * **Written as "star-select" rather than spelled out, deliberately.** The claim is checked by a
 * `grep` for the literal form, so a comment containing it makes that grep answer with itself and the
 * check reports a violation that is a sentence about the check. The first draft of this comment did
 * exactly that. Same family as `CLAUDE.md`'s slash-star gotcha and its warning about a citation that
 * escapes its own parentheses: prose that is also executable text has to be written around the tool
 * that will read it.
 */

/** What is known about an account without reading a byte of content. */
export interface AccountSupportView {
  readonly accountId: string;
  readonly createdAt: Date;
  readonly deletedAt: Date | null;
  readonly trainingConsent: boolean;
  readonly trainingConsentUpdatedAt: Date | null;
  readonly identities: readonly { readonly provider: string; readonly accountClosed: boolean }[];
  readonly usage: {
    readonly events: number;
    readonly oldest: Date | null;
    readonly newest: Date | null;
    readonly byRoute: readonly {
      readonly route: string;
      readonly calls: number;
      readonly outcomes: Readonly<Record<string, number>>;
    }[];
  };
  readonly content: {
    readonly rows: number;
    readonly oldest: Date | null;
    readonly newest: Date | null;
    readonly nextExpiry: Date | null;
    readonly withVoiceAudio: number;
    readonly withScreenshot: number;
    readonly withProviderError: number;
  };
  readonly snapshots: readonly { readonly label: string; readonly rows: number }[];
}

export async function accountSupportView(
  client: pg.Client,
  accountId: string,
): Promise<AccountSupportView | undefined> {
  const account = await client.query<{
    account_id: string;
    created_at: Date;
    deleted_at: Date | null;
    training_consent: boolean;
    training_consent_updated_at: Date | null;
  }>(
    `SELECT id::text AS account_id, created_at, deleted_at, training_consent,
            training_consent_updated_at
       FROM sonny.account WHERE id = $1`,
    [accountId],
  );
  const row = account.rows[0];
  if (row === undefined) return undefined;

  // **`provider` and the closed flag, and deliberately not `subject`.** The subject is the email
  // address for an email identity, and a support view that printed it would put a user's address on
  // a terminal for every lookup — including the ones that turn out to be about somebody else. Which
  // providers an account signs in with is what a support question actually needs.
  const identities = await client.query<{ provider: string; account_closed: boolean }>(
    `SELECT provider, account_closed FROM sonny.identity WHERE account_id = $1 ORDER BY provider`,
    [accountId],
  );

  const span = await client.query<{ events: string; oldest: Date | null; newest: Date | null }>(
    `SELECT count(*)::text AS events, min(occurred_at) AS oldest, max(occurred_at) AS newest
       FROM sonny.metering_event WHERE account_id = $1`,
    [accountId],
  );

  const byRoute = await client.query<{ route: string; outcome: string; calls: string }>(
    `SELECT route, outcome, count(*)::text AS calls
       FROM sonny.metering_event WHERE account_id = $1
      GROUP BY route, outcome ORDER BY route, outcome`,
    [accountId],
  );
  const routes = new Map<string, { calls: number; outcomes: Record<string, number> }>();
  for (const entry of byRoute.rows) {
    const bucket = routes.get(entry.route) ?? { calls: 0, outcomes: {} };
    const calls = Number(entry.calls);
    bucket.calls += calls;
    bucket.outcomes[entry.outcome] = (bucket.outcomes[entry.outcome] ?? 0) + calls;
    routes.set(entry.route, bucket);
  }

  // **Counts and clocks, never the content itself.** `voice_audio IS NOT NULL` says a recording is
  // held without saying anything about what is in it, which is exactly the line requirement 9 draws:
  // a founder can see that there is something to look at and has to ask for it on the record.
  const content = await client.query<{
    rows: string;
    oldest: Date | null;
    newest: Date | null;
    next_expiry: Date | null;
    with_voice_audio: string;
    with_screenshot: string;
    with_provider_error: string;
  }>(
    `SELECT count(*)::text AS rows,
            min(occurred_at) AS oldest,
            max(occurred_at) AS newest,
            min(expires_at) AS next_expiry,
            count(*) FILTER (WHERE voice_audio IS NOT NULL)::text AS with_voice_audio,
            count(*) FILTER (WHERE screenshot IS NOT NULL)::text AS with_screenshot,
            count(*) FILTER (WHERE provider_error_body IS NOT NULL)::text AS with_provider_error
       FROM sonny.retained_content WHERE account_id = $1`,
    [accountId],
  );

  const snapshots = await client.query<{ label: string; rows: string }>(
    `SELECT s.label, count(*)::text AS rows
       FROM sonny.training_snapshot_member m
       JOIN sonny.training_snapshot s ON s.snapshot_id = m.snapshot_id
      WHERE m.account_id = $1
      GROUP BY s.label ORDER BY s.label`,
    [accountId],
  );

  const counts = content.rows[0]!;
  const spanRow = span.rows[0]!;
  return {
    accountId: row.account_id,
    createdAt: row.created_at,
    deletedAt: row.deleted_at,
    trainingConsent: row.training_consent,
    trainingConsentUpdatedAt: row.training_consent_updated_at,
    identities: identities.rows.map((entry) => ({
      provider: entry.provider,
      accountClosed: entry.account_closed,
    })),
    usage: {
      events: Number(spanRow.events),
      oldest: spanRow.oldest,
      newest: spanRow.newest,
      byRoute: [...routes.entries()].map(([route, bucket]) => ({
        route,
        calls: bucket.calls,
        outcomes: bucket.outcomes,
      })),
    },
    content: {
      rows: Number(counts.rows),
      oldest: counts.oldest,
      newest: counts.newest,
      nextExpiry: counts.next_expiry,
      withVoiceAudio: Number(counts.with_voice_audio),
      withScreenshot: Number(counts.with_screenshot),
      withProviderError: Number(counts.with_provider_error),
    },
    snapshots: snapshots.rows.map((entry) => ({ label: entry.label, rows: Number(entry.rows) })),
  };
}

/** One retained call, as the unseal prints it. */
export interface RetainedContentView {
  readonly requestId: string;
  readonly accountId: string;
  readonly taskId: string | null;
  readonly sessionId: string | null;
  readonly sessionIteration: number | null;
  readonly route: string;
  readonly occurredAt: Date;
  readonly expiresAt: Date;
  readonly provider: string | null;
  readonly providerRequestId: string | null;
  readonly requestText: unknown;
  readonly voiceAudioBytes: number | null;
  readonly voiceAudioMediaType: string | null;
  readonly screenshotBytes: number | null;
  readonly screenshotMediaType: string | null;
  readonly responseStatus: number | null;
  readonly responseBody: string | null;
  readonly providerErrorStatus: number | null;
  readonly providerErrorBody: string | null;
}

/**
 * Read one request's content, and record that it was read — in that order, in one transaction.
 *
 * **The access row is written whether or not there was anything to find**, and inside the same
 * transaction as the read. A log that recorded only the hits would understate what was looked for,
 * and a record written outside the transaction is a record that can be lost separately from the
 * thing it describes — the same argument `store.ts` makes about every deletion.
 *
 * **The two blobs come back as sizes and not as bytes.** A terminal cannot render a screenshot or a
 * recording, and printing either would mean a megabyte of base64 in a scrollback that outlives the
 * lookup. What a support question needs from them is that they exist and how big they are; anything
 * more is an export, which is a different act and does not have one.
 */
export async function contentForRequest(
  client: pg.Client,
  lookup: {
    readonly requestId: string;
    readonly operator: string;
    readonly reason: string;
  },
): Promise<RetainedContentView | undefined> {
  await client.query("BEGIN");
  try {
    const { rows } = await client.query<{
      request_id: string;
      account_id: string;
      task_id: string | null;
      session_id: string | null;
      session_iteration: number | null;
      route: string;
      occurred_at: Date;
      expires_at: Date;
      provider: string | null;
      provider_request_id: string | null;
      request_text: unknown;
      voice_audio_bytes: string | null;
      voice_audio_media_type: string | null;
      screenshot_bytes: string | null;
      screenshot_media_type: string | null;
      response_status: number | null;
      response_body: Buffer | null;
      provider_error_status: number | null;
      provider_error_body: string | null;
    }>(
      `SELECT request_id, account_id::text AS account_id, task_id, session_id, session_iteration,
              route, occurred_at, expires_at, provider, provider_request_id, request_text,
              octet_length(voice_audio)::text AS voice_audio_bytes, voice_audio_media_type,
              octet_length(screenshot)::text AS screenshot_bytes, screenshot_media_type,
              response_status, response_body, provider_error_status, provider_error_body
         FROM sonny.retained_content WHERE request_id = $1`,
      [lookup.requestId],
    );
    const row = rows[0];
    await client.query(
      `INSERT INTO sonny.content_access (operator, reason, account_id, request_id, found)
       VALUES ($1, $2, $3, $4, $5)`,
      [
        lookup.operator,
        lookup.reason,
        row?.account_id ?? null,
        lookup.requestId,
        row !== undefined,
      ],
    );
    await client.query("COMMIT");
    if (row === undefined) return undefined;
    return {
      requestId: row.request_id,
      accountId: row.account_id,
      taskId: row.task_id,
      sessionId: row.session_id,
      sessionIteration: row.session_iteration,
      route: row.route,
      occurredAt: row.occurred_at,
      expiresAt: row.expires_at,
      provider: row.provider,
      providerRequestId: row.provider_request_id,
      requestText: row.request_text,
      voiceAudioBytes: row.voice_audio_bytes === null ? null : Number(row.voice_audio_bytes),
      voiceAudioMediaType: row.voice_audio_media_type,
      screenshotBytes: row.screenshot_bytes === null ? null : Number(row.screenshot_bytes),
      screenshotMediaType: row.screenshot_media_type,
      responseStatus: row.response_status,
      responseBody: row.response_body === null ? null : row.response_body.toString("utf8"),
      providerErrorStatus: row.provider_error_status,
      providerErrorBody: row.provider_error_body,
    };
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
}

export interface ContentAccessRow {
  readonly occurredAt: Date;
  readonly operator: string;
  readonly reason: string;
  readonly accountId: string | null;
  readonly requestId: string;
  readonly found: boolean;
}

/** Who has read content, newest first. The trace, readable by the people it is about. */
export async function recentContentAccesses(
  client: pg.Client,
  limit: number,
): Promise<readonly ContentAccessRow[]> {
  const { rows } = await client.query<{
    occurred_at: Date;
    operator: string;
    reason: string;
    account_id: string | null;
    request_id: string;
    found: boolean;
  }>(
    `SELECT occurred_at, operator, reason, account_id::text AS account_id, request_id, found
       FROM sonny.content_access ORDER BY occurred_at DESC LIMIT $1`,
    [limit],
  );
  return rows.map((row) => ({
    occurredAt: row.occurred_at,
    operator: row.operator,
    reason: row.reason,
    accountId: row.account_id,
    requestId: row.request_id,
    found: row.found,
  }));
}

export interface ContentDeletionRow {
  readonly occurredAt: Date;
  readonly reason: string;
  readonly accountId: string | null;
  readonly taskId: string | null;
  readonly contentRows: number;
  readonly snapshotRows: number;
  readonly snapshotsTouched: readonly string[];
  readonly storedResponses: number;
}

/**
 * What has been deleted, newest first.
 *
 * **This is where "expiry actually runs" is answered**, and it is the reason the requirement says
 * *observable* rather than *implemented*: a sweep that took rows left a row here saying so, and a
 * clock that has never run leaves nothing at all. It is also §4.6's traceability — a task delete's
 * row names the snapshots it reached.
 */
export async function recentContentDeletions(
  client: pg.Client,
  window: { readonly accountId?: string | undefined; readonly limit: number },
): Promise<readonly ContentDeletionRow[]> {
  const { rows } = await client.query<{
    occurred_at: Date;
    reason: string;
    account_id: string | null;
    task_id: string | null;
    content_rows: number;
    snapshot_rows: number;
    snapshots_touched: string[];
    stored_responses: number;
  }>(
    `SELECT occurred_at, reason, account_id::text AS account_id, task_id, content_rows,
            snapshot_rows, snapshots_touched::text[] AS snapshots_touched, stored_responses
       FROM sonny.content_deletion
      WHERE ($1::uuid IS NULL OR account_id = $1)
      ORDER BY occurred_at DESC LIMIT $2`,
    [window.accountId ?? null, window.limit],
  );
  return rows.map((row) => ({
    occurredAt: row.occurred_at,
    reason: row.reason,
    accountId: row.account_id,
    taskId: row.task_id,
    contentRows: row.content_rows,
    snapshotRows: row.snapshot_rows,
    snapshotsTouched: row.snapshots_touched,
    storedResponses: row.stored_responses,
  }));
}

export interface SnapshotRow {
  readonly snapshotId: string;
  readonly label: string;
  readonly createdAt: Date;
  readonly sealedAt: Date | null;
  readonly expiresAt: Date | null;
  readonly memberCount: number;
  readonly builderVersion: string;
  readonly routes: readonly string[];
}

export async function trainingSnapshots(client: pg.Client): Promise<readonly SnapshotRow[]> {
  const { rows } = await client.query<{
    snapshot_id: string;
    label: string;
    created_at: Date;
    sealed_at: Date | null;
    expires_at: Date | null;
    member_count: number;
    builder_version: string;
    routes: string[];
  }>(
    `SELECT snapshot_id::text AS snapshot_id, label, created_at, sealed_at, expires_at,
            member_count, builder_version, routes
       FROM sonny.training_snapshot ORDER BY created_at DESC`,
  );
  return rows.map((row) => ({
    snapshotId: row.snapshot_id,
    label: row.label,
    createdAt: row.created_at,
    sealedAt: row.sealed_at,
    expiresAt: row.expires_at,
    memberCount: row.member_count,
    builderVersion: row.builder_version,
    routes: row.routes,
  }));
}
