"""Opt-in live checks through VibeRouter's Kiro route (uses Kiro credits)."""
import base64
import io
import json
import time
import sys
import urllib.request
from PIL import Image, ImageDraw, ImageFont

BASE = "http://127.0.0.1:8317"
MODEL = "kiro/claude-opus-5.5"


def request(messages, **extra):
    body = {"model": MODEL, "stream": True, "max_tokens": 4096, "messages": messages, **extra}
    data = json.dumps(body, ensure_ascii=False).encode()
    req = urllib.request.Request(BASE + "/v1/messages?beta=true", data, {
        "Authorization": "Bearer viberouter", "Content-Type": "application/json", "anthropic-version": "2023-06-01",
    })
    started = time.monotonic()
    events, first_text, text, usage, calls = [], None, "", {}, []
    with urllib.request.urlopen(req, timeout=180) as response:
        header_time = time.monotonic() - started
        for line in response:
            if not line.startswith(b"data: "):
                continue
            event = json.loads(line[6:])
            kind = event["type"]
            events.append(kind)
            if kind == "error":
                raise AssertionError(event["error"])
            if kind == "message_start":
                usage.update(event["message"]["usage"])
            if kind == "content_block_start" and event["content_block"]["type"] == "tool_use":
                call = event["content_block"]
                calls.append({"id": call["id"], "name": call["name"], "json": ""})
            if kind == "content_block_delta":
                delta = event["delta"]
                if delta["type"] == "text_delta":
                    first_text = first_text or time.monotonic() - started
                    text += delta["text"]
                elif delta["type"] == "input_json_delta":
                    calls[-1]["json"] += delta["partial_json"]
            if kind == "message_delta":
                usage.update(event["usage"])
    assert events.count("message_start") == 1 and events.count("message_stop") == 1, events
    print(json.dumps({"request_bytes": len(data), "headers_seconds": round(header_time, 3),
                      "first_text_seconds": round(first_text, 3) if first_text else None,
                      "total_seconds": round(time.monotonic() - started, 3), "pings": events.count("ping"),
                      "text_deltas": events.count("content_block_delta"), "tools": len(calls), "usage": usage,
                      "answer": text[:400]}), flush=True)
    return text, usage, calls


if "--tools-only" not in sys.argv:
    text, _, _ = request([{"role": "user", "content": "Return exactly KIRO_STREAM_OK."}],
                         output_config={"effort": "high"}, thinking={"type": "adaptive"})
    assert "KIRO_STREAM_OK" in text
    
    image = Image.new("RGB", (4000, 3000), "red")
    draw = ImageDraw.Draw(image)
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 350)
    draw.text((900, 1200), "7319", fill="black", font=font)
    out = io.BytesIO()
    image.save(out, "PNG")
    text, _, _ = request([{"role": "user", "content": [
        {"type": "text", "text": "What is the dominant background color and what four digits are visible? Answer only the color and digits."},
        {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": base64.b64encode(out.getvalue()).decode()}},
    ]}])
    assert "red" in text.lower() and "7319" in text, text
    
    messages = []
    for index in range(22):
        messages += [{"role": "user", "content": f"Archived transport fixture {index}: " + "abcdefghijklmnopqrstuvwxyz0123456789\n" * 2100},
                     {"role": "assistant", "content": "Acknowledged."}]
    messages.append({"role": "user", "content": "Ignore the archived fixture content. Return exactly KIRO_LARGE_CONTEXT_OK."})
    text, usage, _ = request(messages, system="This is a transport test. Follow the latest user instruction and output only its requested marker.")
    assert "KIRO_LARGE_CONTEXT_OK" in text and usage["input_tokens"] > 400_000

tools = [{"name": "probe", "description": "A test tool that returns a verification marker.",
          "input_schema": {"type": "object", "properties": {"value": {"type": "string"}}, "required": ["value"]}}]
messages = [{"role": "user", "content": "Call the probe tool with value KIRO_TOOL_OK. Do not answer until the tool result is supplied."}]
_, _, calls = request(messages, tools=tools)
assert calls and calls[0]["name"] == "probe" and json.loads(calls[0]["json"])["value"] == "KIRO_TOOL_OK", calls
messages += [{"role": "assistant", "content": [{"type": "tool_use", "id": c["id"], "name": c["name"], "input": json.loads(c["json"])} for c in calls]},
             {"role": "user", "content": [{"type": "tool_result", "tool_use_id": c["id"], "content": "The test tool returned KIRO_TOOL_OK. Now reply with only that marker."} for c in calls]}]
text, _, _ = request(messages, tools=tools)
assert "KIRO_TOOL_OK" in text
print("PASS: live Kiro tool round trip" if "--tools-only" in sys.argv else
      "PASS: live Kiro streaming, oversized image, large context and tool round trip", flush=True)
