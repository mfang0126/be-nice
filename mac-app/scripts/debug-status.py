#!/usr/bin/env python3
"""Read fresh operational metadata emitted by the running development app."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

bundle = "com.benice.menubar.development"
expected = Path.home() / "Applications/be-nice Development.app"
path = Path.home() / "Library/Application Support/be-nice/debug" / (bundle + ".json")
try:
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError("status must be a JSON object")
    if type(data["updatedAt"]) not in (int, float):
        raise ValueError("invalid update timestamp")
    if type(data["bundleID"]) is not str or type(data["bundlePath"]) is not str:
        raise ValueError("invalid app identity")
    if type(data["accessibilityTrusted"]) is not bool:
        raise ValueError("invalid accessibility trust status")
    age = time.time() - data["updatedAt"]
    if not 0 <= age <= 10:
        raise ValueError("status is stale; launch the installed development app")
    if data["bundleID"] != bundle or Path(data["bundlePath"]) != expected:
        raise ValueError("status belongs to a different app")
    pid = data["pid"]
    if type(pid) is not int or pid <= 0:
        raise ValueError("invalid process ID")
    os.kill(pid, 0)
    process = subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "comm="], text=True).strip()
    if process != str(expected / "Contents/MacOS/benice"):
        raise ValueError("running process path does not match")
    print(json.dumps(data, indent=2))
    sys.exit(0 if data["accessibilityTrusted"] is True else 2)
except (OSError, ValueError, KeyError, OverflowError, subprocess.SubprocessError) as error:
    print(f"Permission status unavailable: {error}", file=sys.stderr)
    sys.exit(1)
