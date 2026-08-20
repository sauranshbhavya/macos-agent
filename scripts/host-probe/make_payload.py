#!/usr/bin/env python3
"""Build a JSON body byte-identical in shape to the one OpenCodeVisionModelClient.decide sends.

Shape copied from Sources/MacAgentCore/VisionModelClient.swift:154-171 (SHA 87199ff): a
{model, input:[{role, content:[input_text, input_image]}]} envelope whose image_url is a
data: URL carrying base64 of the encoded capture.

The blob is base64 of os.urandom, deliberately. Base64 of incompressible bytes deflates to
about 6/8 = 0.75 because gzip recovers base64's own overhead and nothing else -- which is
within a thousandth of the 0.753 floor SONNY-146 measured on a seeded-noise capture. So a
host limit measured against this payload is measured against the worst gzip ratio Sonny can
actually produce, not a flattering one.
"""
import base64, json, os, sys

PROMPT_CHARS = 4673  # SONNY-114's measured shipping prompt, docs/sonny-backend-api-contract.md 6.1


def build(total_bytes: int, media_type: str = "image/jpeg") -> bytes:
    """A body of exactly total_bytes, or raise if that size cannot hold the envelope."""
    # Measure the envelope's own cost by building it once with an empty blob.
    def render(blob: str, prompt: str) -> bytes:
        body = {
            "model": "anthropic/claude-sonnet-4-5",
            "input": [{
                "role": "user",
                "content": [
                    {"type": "input_text", "text": prompt},
                    {"type": "input_image", "image_url": f"data:{media_type};base64,{blob}"},
                ],
            }],
        }
        return json.dumps(body, separators=(",", ":")).encode()

    overhead = len(render("", "x" * PROMPT_CHARS))
    room = total_bytes - overhead
    if room < 0:
        raise SystemExit(f"{total_bytes} is smaller than the {overhead}-byte envelope + prompt")

    # base64 length is always a multiple of 4; absorb the remainder in the prompt so the
    # total is exact rather than approximately right.
    blob_len = (room // 4) * 4
    prompt_len = PROMPT_CHARS + (room - blob_len)
    raw = os.urandom(blob_len // 4 * 3)
    blob = base64.b64encode(raw).decode()[:blob_len]
    out = render(blob, "x" * prompt_len)
    assert len(out) == total_bytes, f"wanted {total_bytes}, built {len(out)}"
    return out


if __name__ == "__main__":
    size, path = int(sys.argv[1]), sys.argv[2]
    data = build(size)
    with open(path, "wb") as handle:
        handle.write(data)
    print(f"{path} {len(data)}")
