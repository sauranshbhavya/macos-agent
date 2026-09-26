/**
 * §4.4's two-part `POST /v1/transcriptions` body, built the way the Mac builds it.
 *
 * Shared because the transcription route is now the gateway's only metered `POST`, so every suite
 * that needs a metered request to drive (metering, the spend cap, idempotency, the version gate)
 * builds this body; one builder means one place that has to agree with the route's parser.
 *
 * `meta` is sent as given when it is a string, so a test can send a part that is not JSON at all.
 */
export function transcriptionBody(
  meta: unknown,
  audio: Buffer,
  options: { readonly filename?: string; readonly contentType?: string } = {},
): { payload: Buffer; contentType: string } {
  const boundary = "SonnyTestBoundary-cbf29ce484222325";
  const head = Buffer.from(
    `--${boundary}\r\n` +
      `Content-Disposition: form-data; name="meta"\r\n` +
      `Content-Type: application/json\r\n\r\n` +
      `${typeof meta === "string" ? meta : JSON.stringify(meta)}\r\n` +
      `--${boundary}\r\n` +
      `Content-Disposition: form-data; name="audio"; filename="${options.filename ?? "voice.m4a"}"\r\n` +
      `Content-Type: ${options.contentType ?? "audio/mp4"}\r\n\r\n`,
    "utf8",
  );
  const tail = Buffer.from(`\r\n--${boundary}--\r\n`, "utf8");
  return {
    payload: Buffer.concat([head, audio, tail]),
    contentType: `multipart/form-data; boundary=${boundary}`,
  };
}
