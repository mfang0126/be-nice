#!/usr/bin/env python3
"""Request one content-free Slack survey from the installed development app."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid


def publish_request(request, payload):
    # A hard link publishes complete bytes atomically and refuses an existing request.
    fd, temporary = tempfile.mkstemp(prefix=".slack-request-", dir=request.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(payload, stream)
        os.link(temporary, request)
    finally:
        os.unlink(temporary)


def main():
    # Validate the running host and its real permission before leaving a request.
    status = subprocess.run([sys.executable, "-I", str(Path(__file__).with_name("debug-status.py"))], capture_output=True, text=True)
    if status.returncode:
        print(status.stderr or status.stdout, end="", file=sys.stderr)
        return status.returncode
    directory = Path.home() / "Library/Application Support/be-nice/debug"
    request = directory / "slack-request.json"
    result = directory / "slack-result.json"
    request_id = str(uuid.uuid4())
    try:
        publish_request(request, {"id": request_id, "requestedAt": time.time()})
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            try:
                report = json.loads(result.read_text())
                if report.get("requestID") == request_id:
                    print(json.dumps(report, indent=2))
                    return 0 if report.get("status") == "ok" else 2
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(0.2)
        print("Diagnostic unavailable: host did not respond within 8 seconds", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"Diagnostic unavailable: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
