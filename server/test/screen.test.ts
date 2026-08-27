import type pg from "pg";
import { afterEach, describe, expect, it, vi } from "vitest";
import { buildApp } from "../src/app.js";
import type { AuthProvider, VerifiedSession } from "../src/auth/provider.js";
import type { Config } from "../src/config.js";
import type { WithConnection } from "../src/db/connection.js";
import {
  BODY_LIMIT_BYTES,
  DEADLINE_MS,
  MAXIMUM_IMAGE_BYTES,
  RESPONSE_LIMIT_BYTES,
  base64Length,
  screenAnalyzeBodyLimitFrom,
} from "../src/model/limits.js";
import { testConfig } from "./support/config.js";
import { accessTokenFor } from "./support/tokens.js";

/**
 * `POST /v1/screen/analyze` — the screen-control route (SONNY-131), contract §4.5.
 *
 * **Every test drives the real app through `inject`, with `fetch` stubbed at the boundary**, for the
 * reason `model.test.ts` gives for the four text routes: what is worth asserting is what the
 * *provider* receives and what the *client* receives, and a test calling the adapter directly would
 * skip the gate, the body limit, the image ceiling, the deadline wrapper and the error mapping —
 * which is where this ticket's requirements actually live.
 *
 * `https://vision.invalid/v1` comes from `testConfig`. `.invalid` is reserved by RFC 2606 and
 * resolves nowhere, so a stub that fails to intercept produces a DNS failure rather than a real
 * request to a real vendor.
 */

const SUPABASE_USER = "0f6c2c4e-8f2a-4a0f-9a11-2b6f5f2a77aa";
const ACCOUNT = "8a1d0c8e-1c5a-4a9f-9f6b-2b6f5f2a77ab";

class UnusedAuthProvider implements AuthProvider {
  async sendEmailCode() {
    return { providerRequestId: undefined };
  }
  async verifyEmailCode(): Promise<VerifiedSession> {
    throw new Error("not used here");
  }
  async refresh(): Promise<VerifiedSession> {
    throw new Error("not used here");
  }
  async signOut() {}
  async userFromAccessToken(): Promise<string> {
    throw new Error("not used here");
  }
  async signOutAllForUser() {}
  async deleteUser() {}
}

/**
 * A connection that answers the gate's one attribution query and nothing else.
 *
 * This route touches no database of its own — metering is SONNY-133's and the content store is
 * SONNY-134's — so anything else reaching this is the route doing something this ticket did not
 * build. It throws rather than returning empty rows, so that is a red test rather than a silent one.
 */
const signedInConnection: WithConnection = async (work) => {
  const client = {
    query: async (text: string) => {
      if (!text.includes("FROM sonny.identity")) {
        throw new Error(`unexpected query from the screen route: ${text}`);
      }
      return { rows: [{ account_id: ACCOUNT }] };
    },
  };
  return work(client as unknown as pg.Client);
};

function build(overrides: Partial<Config> = {}) {
  return buildApp(
    testConfig({
      credentials: [{ provider: "vision", keys: ["vk-test-vision-key", "vk-test-vision-older"] }],
      ...overrides,
    }),
    { provider: new UnusedAuthProvider(), withConnection: signedInConnection },
  );
}

const authorization = () => `Bearer ${accessTokenFor(SUPABASE_USER)}`;

/** A base64 payload of exactly `bytes` decoded bytes. */
function imageOf(bytes: number): string {
  return Buffer.alloc(bytes, 0x41).toString("base64");
}

const SMALL_IMAGE = imageOf(9);

/** §4.5's body, complete. Individual tests drop or bend exactly one field. */
function analyzeBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    task_id: "task-1",
    session_id: "session-1",
    session_iteration: 5,
    retention: "standard",
    prompt: "You are looking at a window. Decide the next action.",
    image: {
      media_type: "image/jpeg",
      encoding: "base64",
      data: SMALL_IMAGE,
      pixel_width: 2406,
      pixel_height: 1354,
    },
    ...overrides,
  };
}

interface StubbedCall {
  url: string;
  method: string | undefined;
  headers: Record<string, string>;
  body: unknown;
}

function stubUpstream(respond: (call: StubbedCall) => Response | Promise<Response> | never): StubbedCall[] {
  const calls: StubbedCall[] = [];
  vi.stubGlobal("fetch", async (input: Parameters<typeof fetch>[0], init?: RequestInit) => {
    const headers: Record<string, string> = {};
    new Headers(init?.headers).forEach((value, key) => {
      headers[key.toLowerCase()] = value;
    });
    let body: unknown = undefined;
    if (typeof init?.body === "string") {
      try {
        body = JSON.parse(init.body);
      } catch {
        body = init.body;
      }
    }
    const call: StubbedCall = { url: String(input), method: init?.method, headers, body };
    calls.push(call);
    return respond(call);
  });
  return calls;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

interface ProviderContent {
  type: string;
  text?: string;
  image_url?: string;
}

function contentOf(call: StubbedCall): ProviderContent[] {
  const sent = call.body as { input: { content: ProviderContent[] }[] };
  return sent.input[0]!.content;
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("POST /v1/screen/analyze", () => {
  it("forwards the client's prompt and its image bytes, unaltered, to the configured model", async () => {
    // §4.5 rules 1 and 2 and §1.3's line, in one assertion. The prompt is assembled by
    // `VisionSessionPromptBuilder` on the Mac — a prompt-injection boundary — so this server
    // forwards it rather than rebuilding it; and the image is spliced into the data URL as the
    // exact base64 the client sent, because the coordinate space the model answers in is the
    // client's `SentImageSize`.
    const calls = stubUpstream(() => jsonResponse({ output_text: '{"action":"done"}' }));
    const app = build();

    const response = await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: { authorization: authorization() },
      payload: analyzeBody({ prompt: "TRUSTED_USER_INSTRUCTION_BEGIN open the file END" }),
    });

    expect(response.statusCode).toBe(200);
    expect(calls).toHaveLength(1);
    const content = contentOf(calls[0]!);
    expect(content[0]!.type).toBe("input_text");
    expect(content[0]!.text).toBe("TRUSTED_USER_INSTRUCTION_BEGIN open the file END");
    expect(content[1]!.type).toBe("input_image");
    expect(content[1]!.image_url).toBe(`data:image/jpeg;base64,${SMALL_IMAGE}`);
    await app.close();
  });

  it("sends the gateway's own credential and the configured model, and the client sends neither", async () => {
    // The ticket in one assertion: the credential, the model identifier and the endpoint are the
    // server's. `theRequestNamesNoProviderNoModelAndNoVendorEndpoint` on the Mac is its other half.
    const calls = stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build();

    await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: { authorization: authorization() },
      payload: analyzeBody(),
    });

    const call = calls[0]!;
    expect(call.url).toBe("https://vision.invalid/v1/responses");
    // Index 0 of the two configured keys — the newest. The older one stays accepted at the provider
    // through a rotation and is never the one sent.
    expect(call.headers["authorization"]).toBe("Bearer vk-test-vision-key");
    expect((call.body as { model: string }).model).toBe("test-vision-model");
    await app.close();
  });

  it("uses the media type the capture carried rather than assuming one", async () => {
    // §4.5 rule 2. `RedactedCaptureEncoder` encodes both PNG and JPEG and sends the smaller, so
    // roughly half of real captures are each — a server that hardcoded either is wrong half the
    // time, which is the exact bug the Mac's own hardcoded `image/png` literal was before SONNY-114.
    const calls = stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build();

    await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: { authorization: authorization() },
      payload: analyzeBody({
        image: {
          media_type: "image/png",
          encoding: "base64",
          data: SMALL_IMAGE,
          pixel_width: 800,
          pixel_height: 600,
        },
      }),
    });

    expect(contentOf(calls[0]!)[1]!.image_url).toBe(`data:image/png;base64,${SMALL_IMAGE}`);
    await app.close();
  });

  it("returns the model's text unmodified, with the request id", async () => {
    stubUpstream(() => jsonResponse({ output_text: '{"action":"click","x":10,"y":20}' }));
    const app = build();

    const response = await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: { authorization: authorization() },
      payload: analyzeBody(),
    });

    const body = response.json();
    // Parsing stays client-side (§1.3): what goes back is the model's string, not a decoded shape.
    expect(body.output_text).toBe('{"action":"click","x":10,"y":20}');
    expect(body.request_id).toBe(response.headers["sonny-request-id"]);
    await app.close();
  });

  it("reads the structured output array when the provider sends no flattened output_text", async () => {
    stubUpstream(() =>
      jsonResponse({ output: [{ content: [{ type: "output_text", text: "from the array" }] }] }),
    );
    const app = build();

    const response = await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: { authorization: authorization() },
      payload: analyzeBody(),
    });

    expect(response.json().output_text).toBe("from the array");
    await app.close();
  });

  // MARK: - usage

  it("passes the provider's own usage numbers through, marked reported", async () => {
    stubUpstream(() =>
      jsonResponse({
        output_text: "{}",
        usage: { input_tokens: 1900, output_tokens: 40, total_tokens: 1940 },
      }),
    );
    const app = build();

    const response = await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: { authorization: authorization() },
      payload: analyzeBody(),
    });

    expect(response.json().usage).toEqual({
      input_tokens: 1900,
      output_tokens: 40,
      total_tokens: 1940,
      audio_duration_seconds: null,
      source: "reported",
    });
    await app.close();
  });

  it("sends no usage block at all when the provider reported nothing, rather than estimating", async () => {
    // **The one place this route deliberately differs from the four text routes.** `openai.ts`
    // estimates from message text at four characters a token; here the text is a small part of a
    // request whose dominant term is an image, and image token cost is a function of pixel
    // dimensions and the provider's own tiling rule. A text-only estimate would not be rough, it
    // would omit most of the cost — on the one route the product charges for.
    //
    // The Mac still records that the call happened: `SonnyWireUsage` is Optional there and
    // `aVisionCallWithNoUsageBlockIsStillCounted` is this assertion's other half.
    stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build();

    const response = await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: { authorization: authorization() },
      payload: analyzeBody(),
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).not.toHaveProperty("usage");
    await app.close();
  });

  // MARK: - the ceiling

  it("refuses an image over the ceiling with 413 request.too_large and both numbers", async () => {
    // §6.2: "The server refuses with `413 request.too_large`, carrying `limit_bytes` and
    // `actual_bytes` so the refusal is diagnosable." A correct client never sees this — the Mac
    // refuses at the same ceiling before it builds a body — so reaching it means the two ceilings
    // have come apart, which is the failure §6.1 says to look for.
    const calls = stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build();
    const oversize = MAXIMUM_IMAGE_BYTES + 1;

    const response = await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: { authorization: authorization() },
      payload: analyzeBody({
        image: {
          media_type: "image/png",
          encoding: "base64",
          data: imageOf(oversize),
          pixel_width: 2560,
          pixel_height: 1440,
        },
      }),
    });

    expect(response.statusCode).toBe(413);
    const error = response.json().error;
    expect(error.code).toBe("request.too_large");
    expect(error.retryable).toBe(false);
    expect(error.limit_bytes).toBe(MAXIMUM_IMAGE_BYTES);
    expect(error.actual_bytes).toBe(oversize);
    // Refused before anything left this gateway, which is the half that costs money.
    expect(calls).toHaveLength(0);
    await app.close();
  });

  it("accepts an image at exactly the ceiling", async () => {
    // The boundary in the other direction, so the refusal above cannot be satisfied by an
    // off-by-one that refuses everything large. This is also the largest body a correct client can
    // build, so it is the one §6.1's limit was derived to carry.
    const calls = stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build();

    const response = await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: { authorization: authorization() },
      payload: analyzeBody({
        image: {
          media_type: "image/jpeg",
          encoding: "base64",
          data: imageOf(MAXIMUM_IMAGE_BYTES),
          pixel_width: 2560,
          pixel_height: 1440,
        },
      }),
    });

    expect(response.statusCode).toBe(200);
    expect(calls).toHaveLength(1);
    await app.close();
  });

  it("refuses a body over the route's own limit before a handler runs", async () => {
    // §6.1's 4,200,000, enforced by Fastify's `bodyLimit` on this route's definition rather than by
    // the 1 MiB server default — which is what a route that forgot to set one would inherit. The
    // padding is a field the schema would reject; it never gets that far, which is the point.
    const calls = stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build();

    const response = await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: { authorization: authorization(), "content-type": "application/json" },
      payload: JSON.stringify({
        ...analyzeBody(),
        padding: "x".repeat(BODY_LIMIT_BYTES.screenAnalyze),
      }),
    });

    expect(response.statusCode).toBe(413);
    expect(response.json().error.code).toBe("request.too_large");
    expect(calls).toHaveLength(0);
    await app.close();
  });

  it("carries a body a megabyte over the server default, which is the whole reason it sets its own limit", async () => {
    // The direction the test above cannot establish. A route with no `bodyLimit` of its own
    // inherits `DEFAULT_BODY_LIMIT_BYTES` (1 MiB) and would refuse this — so swapping this route's
    // limit for the default, or deleting the option, fails here rather than passing quietly.
    const calls = stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build();

    const response = await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: { authorization: authorization() },
      payload: analyzeBody({
        image: {
          media_type: "image/jpeg",
          encoding: "base64",
          data: imageOf(2_000_000),
          pixel_width: 1920,
          pixel_height: 1080,
        },
      }),
    });

    expect(response.statusCode).toBe(200);
    expect(calls).toHaveLength(1);
    await app.close();
  });

  // MARK: - validation

  it("refuses a body with no retention rather than guessing one", async () => {
    // §2.4.2: a loud 400, in either direction. Validated and deliberately not honoured — nothing is
    // stored at all yet, and SONNY-134 builds the store together with §10.1's enforcement point.
    const calls = stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build();
    const body = analyzeBody();
    delete body["retention"];

    const response = await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: { authorization: authorization() },
      payload: body,
    });

    expect(response.statusCode).toBe(400);
    expect(response.json().error.code).toBe("request.invalid");
    expect(calls).toHaveLength(0);
    await app.close();
  });

  it("refuses each of §4.5's required fields when it is missing, and an unknown one when it is present", async () => {
    // The population rather than a sample: every field §4.5 names, dropped one at a time. A schema
    // that made any of them optional would pass a narrower test and fail this one.
    const calls = stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build();

    for (const field of [
      "task_id",
      "session_id",
      "session_iteration",
      "retention",
      "prompt",
      "image",
    ]) {
      const body = analyzeBody();
      delete body[field];
      const response = await app.inject({
        method: "POST",
        url: "/v1/screen/analyze",
        headers: { authorization: authorization() },
        payload: body,
      });
      expect(`${field} -> ${response.statusCode}`).toBe(`${field} -> 400`);
    }

    for (const field of ["media_type", "encoding", "data", "pixel_width", "pixel_height"]) {
      const image = { ...(analyzeBody()["image"] as Record<string, unknown>) };
      delete image[field];
      const response = await app.inject({
        method: "POST",
        url: "/v1/screen/analyze",
        headers: { authorization: authorization() },
        payload: analyzeBody({ image }),
      });
      expect(`image.${field} -> ${response.statusCode}`).toBe(`image.${field} -> 400`);
    }

    // `.strict()`: a field this server silently dropped would be a client believing it asked for
    // something. **Both objects, not just the outer one** — a mutant loosening only `imageObject`
    // survived a version of this test that checked the body alone.
    const extra = await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: { authorization: authorization() },
      payload: analyzeBody({ stream: true }),
    });
    expect(extra.statusCode).toBe(400);

    const extraInImage = await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: { authorization: authorization() },
      payload: analyzeBody({
        image: { ...(analyzeBody()["image"] as Record<string, unknown>), quality: 80 },
      }),
    });
    expect(extraInImage.statusCode).toBe(400);

    expect(calls).toHaveLength(0);
    await app.close();
  });

  it("refuses a media type outside the two the encoder produces", async () => {
    const calls = stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build();

    const response = await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: { authorization: authorization() },
      payload: analyzeBody({
        image: {
          media_type: "image/heic",
          encoding: "base64",
          data: SMALL_IMAGE,
          pixel_width: 800,
          pixel_height: 600,
        },
      }),
    });

    expect(response.statusCode).toBe(400);
    // The value is spliced into a `data:` URL the provider parses, so an open string here would be
    // a client-controlled fragment of a URL this server builds.
    expect(calls).toHaveLength(0);
    await app.close();
  });

  it("refuses image data that is not base64 rather than forwarding a corrupt image", async () => {
    // `Buffer.from(s, "base64")` silently skips characters it does not recognise, so a mangled
    // payload would decode short, pass the ceiling, and reach the provider as a broken image — a
    // failure that surfaces as the model saying something odd about the user's screen, several
    // layers from its cause.
    const calls = stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build();

    for (const data of ["not base64!!", "QUFB@", "QUF"]) {
      const response = await app.inject({
        method: "POST",
        url: "/v1/screen/analyze",
        headers: { authorization: authorization() },
        payload: analyzeBody({
          image: {
            media_type: "image/png",
            encoding: "base64",
            data,
            pixel_width: 800,
            pixel_height: 600,
          },
        }),
      });
      expect(`${data} -> ${response.statusCode}`).toBe(`${data} -> 400`);
    }

    expect(calls).toHaveLength(0);
    await app.close();
  });

  // MARK: - failures

  it("answers 502 provider.unavailable when this deployment holds no vision credential", async () => {
    // Reachable: `./scripts/deploy.sh local` with no `VISION_API_KEY` is exactly this. The route is
    // mounted anyway, because a 404 standing in for a missing key is a code the client reads as "no
    // such route", does not retry, and cannot explain.
    const calls = stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build({ credentials: [] });

    const response = await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: { authorization: authorization() },
      payload: analyzeBody(),
    });

    expect(response.statusCode).toBe(502);
    expect(response.json().error.code).toBe("provider.unavailable");
    expect(response.json().error.retryable).toBe(true);
    expect(calls).toHaveLength(0);
    await app.close();
  });

  it("maps each provider status onto the code §7.2 gives it, not onto the status it saw", async () => {
    // §9.3's rule from the server's side: several statuses carry more than one code with opposite
    // semantics, and the client decides whether to retry on the code. `provider.rejected` and
    // `provider.unavailable` are both 502 and exactly one of them is retried.
    const cases: [number, number, string, boolean][] = [
      [500, 502, "provider.unavailable", true],
      [503, 502, "provider.unavailable", true],
      // The provider rate-limiting *this gateway* is a fact about our account, not the user's — so
      // it is retryable and must never surface as `limit.rate`, which §7.2 defines as the user's own.
      [429, 502, "provider.unavailable", true],
      [504, 504, "provider.timeout", true],
      [408, 504, "provider.timeout", true],
      [400, 502, "provider.rejected", false],
      [422, 502, "provider.rejected", false],
    ];

    for (const [upstream, status, code, retryable] of cases) {
      stubUpstream(() => jsonResponse({ error: "upstream said so" }, upstream));
      const app = build();
      const response = await app.inject({
        method: "POST",
        url: "/v1/screen/analyze",
        headers: { authorization: authorization() },
        payload: analyzeBody(),
      });
      expect(`${upstream} -> ${response.statusCode} ${response.json().error.code}`)
        .toBe(`${upstream} -> ${status} ${code}`);
      expect(response.json().error.retryable).toBe(retryable);
      // §7.1: the client never displays `message`, so what is here is for logs and the support
      // lookup — and it must not be the provider's own body, which can echo the prompt back.
      expect(response.json().error.message).not.toContain("upstream said so");
      await app.close();
      vi.unstubAllGlobals();
    }
  });

  it("answers 502 provider.rejected when the provider returns 2xx with no text output", async () => {
    stubUpstream(() => jsonResponse({ output: [] }));
    const app = build();

    const response = await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: { authorization: authorization() },
      payload: analyzeBody(),
    });

    expect(response.statusCode).toBe(502);
    // `rejected` rather than `unavailable`: a retry produces the same unreadable reply, and §9.3
    // must not send the client back for it.
    expect(response.json().error.code).toBe("provider.rejected");
    expect(response.json().error.retryable).toBe(false);
    await app.close();
  });

  it("refuses a provider reply whose declared length is over §6.3's cap, before reading a byte of it", async () => {
    // §6.3 exists so an unexpected provider reply cannot become an unbounded client-side
    // allocation — so the check has to come before the read, not after it. `content-length` is the
    // cheap half: a provider that sends one is refused without the body ever being pulled.
    const body = JSON.stringify({ output_text: "small enough to use" });
    stubUpstream(
      () =>
        new Response(body, {
          status: 200,
          headers: {
            "content-type": "application/json",
            // The header lies about the body, which is the point: what is under test is that the
            // declared length is believed and refused on, ahead of the read.
            "content-length": String(RESPONSE_LIMIT_BYTES + 1),
          },
        }),
    );
    const app = build();

    const response = await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: { authorization: authorization() },
      payload: analyzeBody(),
    });

    expect(response.statusCode).toBe(502);
    // `rejected` rather than `unavailable`, on `openai.ts`' precedent for a 2xx body it cannot use:
    // a retry produces the same unusable reply, so §9.3 must not send the client back for it.
    expect(response.json().error.code).toBe("provider.rejected");
    await app.close();
  });

  it("stops pulling a chunked reply once it passes the cap, rather than reading it all and then measuring", async () => {
    // The half `content-length` cannot cover — a chunked reply carries no length to believe — and
    // **the assertion is how much was pulled, not the status code.** That is not a stylistic
    // preference: §6.3 is about the allocation, and every status a too-big reply can produce is
    // `502 provider.rejected` whether the cap fired or the parse did. A first draft asserted only
    // the status and a mutant deleting this check survived, because the route's *outgoing* size
    // check caught the same body one layer later and answered identically.
    //
    // The stream produces on demand, so chunks pulled is exactly what the reader consumed.
    const CHUNK = 64 * 1024;
    const CHUNKS = 32; // 2 MiB, twice the cap.
    let pulled = 0;
    stubUpstream(
      () =>
        new Response(
          new ReadableStream({
            pull(controller) {
              if (pulled === CHUNKS) {
                controller.close();
                return;
              }
              pulled += 1;
              controller.enqueue(new Uint8Array(Buffer.alloc(CHUNK, 0x20)));
            },
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        ),
    );
    const app = build();

    const response = await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: { authorization: authorization() },
      payload: analyzeBody(),
    });

    // One chunk past the cap is where it can stop, and a stream may run one chunk ahead of the
    // reader — so the bound is generous while still being far short of the whole body.
    expect(pulled).toBeLessThanOrEqual(RESPONSE_LIMIT_BYTES / CHUNK + 2);
    expect(pulled).toBeLessThan(CHUNKS);
    expect(response.statusCode).toBe(502);
    expect(response.json().error.code).toBe("provider.rejected");
    await app.close();
  });

  it("refuses to send a response over the cap even when the provider's reply was under it", async () => {
    // The route's own outgoing check, and it is reachable rather than decorative: the adapter caps
    // what it *reads*, and the envelope this route adds — `request_id` and the JSON around it — is
    // enough to push a reply that was just under the cap over it. §6.3 caps the response, not the
    // provider's body, so the measurement is on the bytes that leave.
    const text = "x".repeat(RESPONSE_LIMIT_BYTES - 40);
    const providerBody = JSON.stringify({ output_text: text });
    expect(Buffer.byteLength(providerBody, "utf8")).toBeLessThanOrEqual(RESPONSE_LIMIT_BYTES);
    stubUpstream(() => jsonResponse({ output_text: text }));
    const app = build();

    const response = await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: { authorization: authorization() },
      payload: analyzeBody(),
    });

    expect(response.statusCode).toBe(502);
    expect(response.json().error.code).toBe("provider.rejected");
    await app.close();
  });

  it("answers 504 provider.timeout when the upstream deadline aborts the provider call", async () => {
    // §12's *upstream* deadline — the `AbortSignal` the wrapper owns, which is what ends a provider
    // call that is still open. `upstreamTransportError` turns the resulting `AbortError` into
    // `ProviderTimedOut`, and that distinction is load-bearing: it must not read as "the provider is
    // down", because §9.3 retries `provider.timeout` once and `provider.unavailable` with backoff.
    //
    // Driven with fake timers rather than by waiting ninety seconds, and the stub honours the signal
    // the way a real `fetch` does — so this is the abort path, not the race below.
    vi.useFakeTimers();
    try {
      vi.stubGlobal(
        "fetch",
        (_input: unknown, init?: RequestInit) =>
          new Promise<Response>((_resolve, reject) => {
            init?.signal?.addEventListener("abort", () => {
              reject(new DOMException("aborted", "AbortError"));
            });
          }),
      );
      const app = build();
      const pending = app.inject({
        method: "POST",
        url: "/v1/screen/analyze",
        headers: { authorization: authorization() },
        payload: analyzeBody(),
      });
      let settled = false;
      void pending.then(() => {
        settled = true;
      });

      // Nothing has answered one millisecond before the upstream deadline, which is what makes the
      // assertion after it about the deadline rather than about the stub.
      await vi.advanceTimersByTimeAsync(DEADLINE_MS.screenAnalyze.upstream - 1);
      expect(settled).toBe(false);

      await vi.advanceTimersByTimeAsync(2);
      const response = await pending;
      expect(response.statusCode).toBe(504);
      expect(response.json().error.code).toBe("provider.timeout");
      expect(response.json().error.retryable).toBe(true);
      await app.close();
    } finally {
      vi.useRealTimers();
    }
  });

  it("answers 504 provider.timeout when the handler outruns the total deadline having ignored the signal", async () => {
    // The second of §12's two deadlines, and the reason there are two: the signal ends a provider
    // call that is still open, while the total-deadline race ends a handler stuck anywhere else —
    // an adapter that resolved and then hung, or one that simply does not honour an abort. Without
    // it, §12's "server total deadline" column would be a number nothing enforces, and the failure
    // would arrive as whatever the platform in front does when it gives up.
    vi.useFakeTimers();
    try {
      // Deliberately ignores the signal, so the upstream deadline above cannot be what ends this.
      vi.stubGlobal("fetch", () => new Promise<Response>(() => {}));
      const app = build();
      const pending = app.inject({
        method: "POST",
        url: "/v1/screen/analyze",
        headers: { authorization: authorization() },
        payload: analyzeBody(),
      });
      let settled = false;
      void pending.then(() => {
        settled = true;
      });

      await vi.advanceTimersByTimeAsync(DEADLINE_MS.screenAnalyze.upstream + 1_000);
      // Past the upstream deadline and still open, which is the state this second deadline is for.
      expect(settled).toBe(false);

      await vi.advanceTimersByTimeAsync(
        DEADLINE_MS.screenAnalyze.total - DEADLINE_MS.screenAnalyze.upstream,
      );
      const response = await pending;
      expect(response.statusCode).toBe(504);
      expect(response.json().error.code).toBe("provider.timeout");
      await app.close();
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("the screen route's numbers", () => {
  it("derives §6.1's body limit from the client's image ceiling rather than holding a second literal", () => {
    // §6.1: "This number and SONNY-114's are one number. If `maximumImageBytes` ever moves, this
    // limit is re-derived in the same change." Derived rather than asserted equal, so moving the
    // ceiling moves the limit and there is no second literal to forget.
    expect(MAXIMUM_IMAGE_BYTES).toBe(3_000_000);
    expect(base64Length(MAXIMUM_IMAGE_BYTES)).toBe(4_000_000);
    expect(BODY_LIMIT_BYTES.screenAnalyze).toBe(screenAnalyzeBodyLimitFrom(MAXIMUM_IMAGE_BYTES));
    // And it is §6.1's published figure, so the contract and this file agree.
    expect(BODY_LIMIT_BYTES.screenAnalyze).toBe(4_200_000);
  });

  it("leaves the headroom §6.1 says it does, and no more", () => {
    // §6.1: "4,200,000 leaves roughly 190,000 bytes of headroom over the largest body the client can
    // build, which is about forty times the measured prompt." The limit is set as low as the
    // client's own ceiling allows on purpose — every byte above that eliminates hosts for nothing.
    const headroom = BODY_LIMIT_BYTES.screenAnalyze - base64Length(MAXIMUM_IMAGE_BYTES);
    expect(headroom).toBe(200_000);
    // 4,673 characters was SONNY-114's measured prompt; the headroom is far above it. The SHA that
    // figure was taken at is in `limits.ts`, beside the note on why it is deliberately non-ancestral.
    expect(headroom).toBeGreaterThan(4_673 * 10);
  });

  it("holds §12's deadlines for this route and keeps the upstream one inside the total", () => {
    // The server half of §12's table. `ModelRouteNumbersTests` on the Mac holds the same row as a
    // literal, so neither side can move without the other failing — which is the only way to pin a
    // relation between two codebases that cannot see each other.
    expect(DEADLINE_MS.screenAnalyze).toEqual({ upstream: 90_000, total: 105_000 });
    expect(DEADLINE_MS.screenAnalyze.upstream).toBeLessThan(DEADLINE_MS.screenAnalyze.total);
  });
});
