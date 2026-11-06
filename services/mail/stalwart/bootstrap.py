#!/usr/bin/env python3
"""Explicit first-install bootstrap; never part of ordinary settings regeneration."""
import base64
import json
import os
from pathlib import Path
import sys
import urllib.request

if sys.argv[1:] != ["--new-install"]:
    raise SystemExit("First install only: bootstrap.py --new-install")
password = os.environ["STALWART_ADMIN_PASSWORD"]
user = os.environ.get("STALWART_ADMIN_USER", "admin")
config = json.loads(Path(os.environ.get("STALWART_CONFIG_DIR", "/etc/stalwart"), "bootstrap.json").read_text())
request = urllib.request.Request(
    os.environ.get("STALWART_API_URL", "http://stalwart:8080").rstrip("/") + "/jmap/",
    data=json.dumps({"using": ["urn:ietf:params:jmap:core", "urn:stalwart:jmap"],
                     "methodCalls": [["x:Bootstrap/set", {"update": {"singleton": config}}, "bootstrap"]]}).encode(),
    headers={"Content-Type": "application/json",
             "Authorization": "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()},
)
with urllib.request.urlopen(request, timeout=120) as response:
    method, result, _ = json.load(response)["methodResponses"][0]
if method != "x:Bootstrap/set" or "singleton" not in result.get("updated", {}):
    raise SystemExit("Bootstrap refused: " + json.dumps(result.get("notUpdated", result)))
print("Stalwart initialized. Restart, then apply ordinary settings.")
