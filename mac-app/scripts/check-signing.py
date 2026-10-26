#!/usr/bin/env python3
"""Deterministic fail-closed checks; never generate keys or invoke a build."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

scripts = Path(__file__).resolve().parent
for name in ("build-app.sh", "setup-dev-signing.sh"):
    subprocess.run(["/bin/sh", "-n", str(scripts / name)], check=True)

with tempfile.TemporaryDirectory(prefix="be-nice-signing-check-") as home:
    env = dict(os.environ, HOME=home)
    cases = [
        ("setup-dev-signing.sh", [], 2, "usage:"),
        ("setup-dev-signing.sh", ["--setup", "extra"], 2, "usage:"),
        ("build-app.sh", ["release"], 2, "distribution signing is not configured"),
        ("build-app.sh", ["debug", "--invalid"], 2, "usage:"),
        ("build-app.sh", [], 1, "Stable development certificate missing"),
        ("build-app.sh", ["debug", "--install"], 1, "Stable development certificate missing"),
        ("build-app.sh", ["release-local"], 1, "Stable development certificate missing"),
    ]
    for script, args, code, message in cases:
        result = subprocess.run(["/bin/sh", str(scripts / script), *args],
                                env=env, text=True, capture_output=True)
        assert result.returncode == code, (script, args, result)
        assert message in result.stderr, (script, args, result.stderr)
    assert not list(Path(home).iterdir()), "Preflight unexpectedly changed HOME"

# A malformed existing certificate must fail before any keychain command.
with tempfile.TemporaryDirectory(prefix="be-nice-invalid-cert-") as home:
    directory = Path(home) / "Library/Application Support/be-nice/dev-signing"
    directory.mkdir(parents=True)
    (directory / "certificate.pem").write_text("not a certificate\n")
    result = subprocess.run(["/bin/sh", str(scripts / "setup-dev-signing.sh"), "--setup"],
                            env=dict(os.environ, HOME=home), text=True, capture_output=True)
    assert result.returncode == 1, result
    assert "Invalid development certificate" in result.stderr, result.stderr
    assert not (directory / "private-key.pem").exists()

# Exercise lifecycle with isolated command substitutes, never the real keychain.
with tempfile.TemporaryDirectory(prefix="be-nice-signing-lifecycle-") as temporary:
    root = Path(temporary)
    fake = root / "fake-command"
    fake.write_text('''#!/bin/sh
case "$1" in
    genrsa)
        [ "$#" = 4 ] && [ "$2" = -out ] && [ "$3" = "$KEY_FILE" ] && [ "$4" = 3072 ] || exit 91
        printf 'RSA private key' > "$KEY_FILE" ;;
    req)
        [ "$2" = -new ] && [ "$3" = -x509 ] && [ "$4" = -key ] && [ "$5" = "$KEY_FILE" ] || exit 92
        [ -s "$KEY_FILE" ] || exit 93
        for argument do
            case "$argument" in -newkey|-keyout) exit 94 ;; esac
        done
        printf cert > "$CERT_FILE" ;;
    x509) printf 'sha1 Fingerprint=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\\n' ;;
    find-identity) [ ! -e "$VALID_FILE" ] || printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\\n' ;;
    import) touch "$IMPORT_FILE" ;;
    add-trusted-cert) touch "$VALID_FILE" ;;
    --force) [ "${FAIL_SIGN:-0}" != 1 ] || exit 1 ;;
    --verify) [ "${FAIL_VERIFY:-0}" != 1 ] || exit 1 ;;
    *) exit 90 ;;
esac
''')
    fake.chmod(0o700)
    source = (scripts / "setup-dev-signing.sh").read_text()
    for command in ("openssl", "security", "codesign"):
        source = source.replace(f"/usr/bin/{command}", str(fake))
    isolated = root / "setup.sh"
    isolated.write_text(source)
    for case in ("success", "sign-failure", "verify-failure", "missing-identity", "incomplete"):
        home = root / case
        directory = home / "Library/Application Support/be-nice/dev-signing"
        directory.mkdir(parents=True)
        key = directory / "private-key.pem"
        cert = directory / "certificate.pem"
        valid = home / "valid"
        imported = home / "imported"
        env = dict(os.environ, HOME=str(home), KEY_FILE=str(key), CERT_FILE=str(cert),
                   VALID_FILE=str(valid), IMPORT_FILE=str(imported),
                   FAIL_SIGN=str(int(case == "sign-failure")),
                   FAIL_VERIFY=str(int(case == "verify-failure")))
        if case in ("missing-identity", "incomplete"):
            cert.write_text("established certificate")
        if case == "incomplete":
            key.write_text("retained private key")
        result = subprocess.run(["/bin/sh", str(isolated), "--setup"], env=env,
                                text=True, capture_output=True)
        assert (result.returncode == 0) == (case == "success"), (case, result)
        if case == "success":
            assert not key.exists() and valid.exists()
            imported.unlink()
            result = subprocess.run(["/bin/sh", str(isolated), "--setup"], env=env,
                                    text=True, capture_output=True)
            assert result.returncode == 0 and not imported.exists(), result
        elif case == "missing-identity":
            assert not key.exists() and not imported.exists()
        else:
            assert key.exists(), "Failed setup must retain private key"
            assert key.stat().st_mode & 0o777 == 0o600
            if case == "incomplete":
                assert key.read_text() == "retained private key" and not imported.exists()
        assert directory.stat().st_mode & 0o777 == 0o700

build = (scripts / "build-app.sh").read_text()
setup = (scripts / "setup-dev-signing.sh").read_text()
assert '--sign - ' not in build
signing = next(command for command in build.replace('\\\n', ' ').splitlines()
               if command.startswith('/usr/bin/codesign --force '))
signing_args = shlex.split(signing)
requirement = signing_args[signing_args.index('-r') + 1]
assert requirement == '=designated => identifier "com.benice.menubar.development" and certificate leaf = H"$HASH"', requirement
assert '-T /usr/bin/codesign' in setup and ' -A' not in setup
trust = next(line for line in setup.splitlines() if '/usr/bin/security add-trusted-cert ' in line)
assert ' -d ' not in trust and ' -P ' not in setup
assert '-p codeSign' in setup and 'umask 077' in setup
print(f"PASS: shell syntax, {len(cases)} preflight cases, malformed certificate, 5 isolated lifecycle cases plus rerun, signing safety invariants")
