#!/usr/bin/env python3
"""Isolated read-only app-server fixture. Never opens a real Codex home."""
import json
import pathlib
import sys
import time

scenario = pathlib.Path(__file__).with_name("scenario.txt").read_text().strip()
log = pathlib.Path(__file__).with_name("methods.jsonl")
account = {"type": "chatgpt", "email": "fixture@example.invalid", "planType": "plus"}
for line in sys.stdin:
    request = json.loads(line)
    method = request["method"]
    with log.open("a") as output:
        output.write(json.dumps(method) + "\n")
    if method == "initialized":
        continue
    if scenario == "timeout":
        time.sleep(20)
    if method == "initialize":
        result = {"userAgent": "fixture"}
    elif method == "account/read":
        value = dict(account)
        if scenario == "signedout":
            value = None
        elif scenario == "apikey":
            value = {"type": "apiKey"}
        elif scenario == "identitychanged" and request["id"] == 4:
            value["email"] = "different@example.invalid"
        result = {"account": value}
    elif method == "account/rateLimits/read":
        if scenario == "limited":
            print(json.dumps({"id": request["id"], "error": {"code": -32000, "message": "HTTP 429"}}), flush=True)
            continue
        window = {"usedPercent": 53, "windowDurationMins": 10080, "resetsAt": 1793776148}
        result = {"rateLimits": {"limitId": "codex", "primary": window, "secondary": None}}
    else:
        raise AssertionError("Unexpected method: " + method)
    # Coalesced notification + response and split writes exercise buffered framing.
    payload = json.dumps({"method": "fixture/notice", "params": {}}) + "\n"
    payload += json.dumps({"id": request["id"], "result": result}) + "\n"
    sys.stdout.write(payload[:7])
    sys.stdout.flush()
    sys.stdout.write(payload[7:])
    sys.stdout.flush()
