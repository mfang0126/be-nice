#!/usr/bin/env python3
"""Deterministic transport check; no running app, AX, or user data needed."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "slack_diagnostic", Path(__file__).with_name("slack-diagnostic.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as directory:
    request = Path(directory) / "slack-request.json"
    payload = {"id": "test-request", "requestedAt": 123.0}
    link = os.link
    observations = []

    def inspect_publication(source, destination):
        assert not request.exists(), "Request must stay invisible until fully written"
        assert json.loads(Path(source).read_text()) == payload
        link(source, destination)
        assert json.loads(request.read_text()) == payload
        assert request.stat().st_mode & 0o777 == 0o600
        observations.append(True)

    with patch.object(module.os, "link", inspect_publication):
        module.publish_request(request, payload)
    assert observations == [True]
    original = request.read_bytes()
    try:
        module.publish_request(request, {"id": "replacement"})
    except FileExistsError:
        pass
    else:
        raise AssertionError("An existing request must not be overwritten")
    assert request.read_bytes() == original
    assert list(Path(directory).iterdir()) == [request], "Temporary files must be removed"

print("Slack diagnostic transport check passed (atomic, exclusive, private publication)")
