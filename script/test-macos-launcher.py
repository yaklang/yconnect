#!/usr/bin/env python3
"""Exercise the real Swift runner with a controlling PTY, a fake key and keyboard input."""
import argparse
import json
import os
import pathlib
import pty
import select
import signal
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=pathlib.Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    with tempfile.TemporaryDirectory(prefix="yconnect-tty-test-") as temporary:
        root = pathlib.Path(temporary)
        secret = root / "fixture-key"
        secret.write_text("fake-pty-test-key")
        secret.chmod(0o600)
        manifest = root / "session.json"
        manifest.write_text(json.dumps({
            "clientID": "fixture", "model": "fixture-model", "executable": "/bin/zsh",
            "arguments": ["-f", "-c", 'print -r -- TTY_READY; read -r answer; [[ "$answer" == "fixture-input" ]] && print -r -- TTY_PASSED'],
            "directory": str(root), "variables": {}, "removeVariables": [],
            "secretPath": str(secret), "autoStart": True,
            "expiresAt": time.time() - 978307200 + 120,
        }))
        manifest.chmod(0o600)
        pid, fd = pty.fork()
        if pid == 0:
            os.execv(str(binary), [str(binary), "--run-agent-session", str(manifest)])
        output = b""
        sent = False
        finished = False
        deadline = time.monotonic() + 20
        try:
            while time.monotonic() < deadline:
                if select.select([fd], [], [], 0.1)[0]:
                    try:
                        part = os.read(fd, 65536)
                    except OSError:
                        part = b""
                    output += part
                    if b"TTY_READY" in output and not sent:
                        os.write(fd, b"fixture-input\n")
                        sent = True
                waited, code = os.waitpid(pid, os.WNOHANG)
                if waited:
                    finished = True
                    assert os.waitstatus_to_exitcode(code) == 0, output.decode(errors="replace")
                    break
            assert finished and b"TTY_PASSED" in output, "Agent could not receive terminal input"
            assert not secret.exists(), "Session credential was not removed after exit"
            assert (root / "ready").exists(), "Runner did not acknowledge process startup"
            print("PASS: real PTY input, foreground handoff, process exit, credential cleanup")
        finally:
            if not finished:
                if (root / "ready").exists():
                    child = int((root / "ready").read_text())
                    try:
                        os.kill(child, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                try:
                    os.kill(pid, signal.SIGKILL)
                    os.waitpid(pid, 0)
                except ProcessLookupError:
                    pass
            os.close(fd)


if __name__ == "__main__":
    main()
