#!/usr/bin/env python3
"""Isolated metadata regressions; no live processes, keychain, or GUI."""
import contextlib
import io
import json
from pathlib import Path
import runpy
import subprocess
import tempfile
from unittest.mock import patch

scripts = Path(__file__).resolve().parent
count = 0
with tempfile.TemporaryDirectory(prefix="be-nice-status-check-") as temporary:
    home = Path(temporary)
    app = home / "Applications/be-nice Development.app"
    path = home / "Library/Application Support/be-nice/debug/com.benice.menubar.development.json"
    path.parent.mkdir(parents=True)
    valid = dict(updatedAt=1000, bundleID="com.benice.menubar.development",
                 bundlePath=str(app), pid=123, accessibilityTrusted=True)

    def check(name, data=valid, code=1, raw=None, missing=False, kill_error=None,
              process=None, process_error=None):
        global count
        if missing:
            path.unlink(missing_ok=True)
        else:
            path.write_text(raw if raw is not None else json.dumps(data))
        out, err = io.StringIO(), io.StringIO()
        with patch.object(Path, "home", return_value=home), \
                patch("time.time", return_value=1000), \
                patch("os.kill", side_effect=kill_error) as kill, \
                patch("subprocess.check_output", side_effect=process_error,
                      return_value=process if process is not None else str(app / "Contents/MacOS/benice") + "\n") as ps, \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                runpy.run_path(str(scripts / "debug-status.py"), run_name="__main__")
            except SystemExit as result:
                assert result.code == code, (name, result.code, err.getvalue())
            else:
                raise AssertionError((name, "did not exit"))
        if code == 1:
            assert "Permission status unavailable:" in err.getvalue(), (name, err.getvalue())
            assert not out.getvalue(), (name, out.getvalue())
        else:
            assert json.loads(out.getvalue()) == data and not err.getvalue(), name
            kill.assert_called_once_with(123, 0)
            ps.assert_called_once_with(["/bin/ps", "-p", "123", "-o", "comm="], text=True)
        count += 1

    check("missing", missing=True)
    check("corrupt", raw="{")
    for value in (None, [], "status", 1, True):
        check("root type", data=value)
    for key in valid:
        check("missing " + key, data={k: v for k, v in valid.items() if k != key})
    for key, values in {
        "updatedAt": [None, "1000", [], {}, True, float("nan"), float("inf"), 10 ** 400],
        "bundleID": [None, [], {}, 1, True, "other.bundle"],
        "bundlePath": [None, [], {}, 1, True, "/other.app"],
        "pid": [None, [], {}, "123", True, 0, -1, 1.5],
        "accessibilityTrusted": [None, [], {}, "true", "false", 0, 1],
    }.items():
        for value in values:
            check("invalid " + key, data={**valid, key: value})
    check("stale", data={**valid, "updatedAt": 989.9})
    check("future", data={**valid, "updatedAt": 1000.1})
    check("dead PID", kill_error=ProcessLookupError("process exited"))
    check("denied PID", kill_error=PermissionError("process inaccessible"))
    check("overflow PID", data={**valid, "pid": 10 ** 100}, kill_error=OverflowError("PID too large"))
    check("wrong process", process="/other/benice")
    check("ps failure", process_error=subprocess.CalledProcessError(1, "ps"))
    check("trusted", code=0)
    check("untrusted", data={**valid, "accessibilityTrusted": False}, code=2)
    check("freshness boundary", data={**valid, "updatedAt": 990}, code=0)

print(f"PASS: {count} isolated debug-status cases")
