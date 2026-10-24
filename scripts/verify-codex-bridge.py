#!/usr/bin/env python3
"""Exercise the packaged hook using disposable mailboxes; never configure or call a real agent."""
import json
import pathlib
import subprocess
import sys
import tempfile
import time


def wait_event(root, kind):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        for path in root.glob("*.event"):
            event = json.loads(path.read_text())
            if event["kind"] == kind:
                return event
        time.sleep(0.02)
    raise AssertionError("Hook event not received: " + kind)


def exercise(binary, choice):
    with tempfile.TemporaryDirectory(prefix="BetterNotch-Codex-QA-") as temp:
        root = pathlib.Path(temp)
        root.chmod(0o700)
        (root / "heartbeat").write_text(json.dumps(time.time()))
        proc = subprocess.Popen([binary, "--root", str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        payload = {"hook_event_name": "PermissionRequest", "session_id": "qa-thread", "turn_id": "qa-turn", "tool_name": "Bash", "tool_input": {"command": "echo fixture-only"}}
        proc.stdin.write(json.dumps(payload).encode())
        proc.stdin.close()
        event = wait_event(root, "approval")
        response = {"eventID": event["id"], "threadID": "wrong-thread", "turnID": "qa-turn", "choice": "allow"}
        reply_path = root / (event["id"] + ".response")
        reply_path.write_text(json.dumps(response))
        time.sleep(0.2)
        assert proc.poll() is None, "A reply for another thread must never approve the request"
        if choice == "disconnected":
            (root / "heartbeat").unlink()
        else:
            response["threadID"] = "qa-thread"
            response["choice"] = choice
            staging = root / "reply.tmp"
            staging.write_text(json.dumps(response))
            staging.replace(reply_path)
        proc.wait(timeout=5)
        output, error = proc.stdout.read(), proc.stderr.read()
        assert proc.returncode == 0 and not error
        if choice in ["codex", "disconnected"]:
            assert output == b"", "Fallback must leave Codex's normal approval flow intact"
        else:
            assert json.loads(output)["hookSpecificOutput"]["decision"]["behavior"] == choice
        acknowledgement = wait_event(root, "resolved")
        assert acknowledgement["resolvesID"] == event["id"]
        assert not reply_path.exists()


def main():
    binary = str(pathlib.Path(sys.argv[1]).resolve())
    for choice in ["allow", "deny", "codex", "disconnected"]:
        exercise(binary, choice)
    with tempfile.TemporaryDirectory(prefix="BetterNotch-Codex-QA-") as temp:
        root = pathlib.Path(temp)
        payload = {"hook_event_name": "Stop", "session_id": "qa-thread", "last_assistant_message": "x" * 150_000}
        result = subprocess.run([binary, "--root", temp], input=json.dumps(payload).encode(), capture_output=True, timeout=5)
        assert result.stdout == b"" and not list(root.glob("*.event")), "A disconnected app must have no hook side effects"
        (root / "heartbeat").write_text(json.dumps(time.time()))
        result = subprocess.run([binary, "--root", temp], input=json.dumps(payload).encode(), capture_output=True, timeout=5)
        event = wait_event(root, "completed")
        assert len(event["message"]) < 24_200 and "truncated" in event["message"]
        assert result.stdout == b"" and result.stderr == b""
    print("Codex bridge: allow, deny, handoff, disconnect, wrong-thread rejection, and bounded multi-read input passed.")


if __name__ == "__main__":
    main()
