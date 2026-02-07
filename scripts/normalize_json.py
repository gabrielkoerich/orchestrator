#!/usr/bin/env python3
import json
import os
import sys


def strip_fences(text: str) -> str:
    if "```" not in text:
        return text
    parts = text.split("```")
    if len(parts) >= 3:
        body = parts[1]
        if body.startswith("json"):
            body = body[len("json") :]
        if body.startswith("\n"):
            body = body[1:]
        return body
    return text


def parse_payload(payload):
    if isinstance(payload, str):
        if "```" in payload:
            parts = payload.split("```")
            if len(parts) >= 3:
                payload = parts[1]
        text = strip_fences(payload).strip()
        if text.startswith("json"):
            text = text[len("json") :].lstrip()
        try:
            return json.loads(text)
        except Exception:
            return json.loads(json.dumps(text))
    return payload


def normalize(raw: str):
    try:
        obj = json.loads(raw)
        if isinstance(obj, dict) and "result" in obj:
            parsed = parse_payload(obj["result"])
        else:
            parsed = parse_payload(obj)
        return json.dumps(parsed, separators=(",", ":"))
    except Exception:
        pass

    lines = [l for l in raw.splitlines() if l.strip().startswith("{")]
    events = []
    for line in lines:
        try:
            events.append(json.loads(line))
        except Exception:
            continue

    for ev in reversed(events):
        if ev.get("type") == "text":
            text = ev.get("part", {}).get("text", "")
            if text:
                parsed = parse_payload(text)
                return json.dumps(parsed, separators=(",", ":"))

    for ev in reversed(events):
        if ev.get("type") == "item.completed":
            item = ev.get("item", {})
            if item.get("type") == "agent_message":
                text = item.get("text", "")
                if text:
                    parsed = parse_payload(text)
                    return json.dumps(parsed, separators=(",", ":"))

    return None


def main():
    raw = os.environ.get("RAW_RESPONSE")
    if raw is None:
        raw = sys.stdin.read()

    if not raw:
        sys.exit(1)

    out = normalize(raw)
    if out is None:
        sys.exit(1)
    print(out)


if __name__ == "__main__":
    main()
