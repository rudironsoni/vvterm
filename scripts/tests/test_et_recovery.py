#!/usr/bin/env python3
"""Run the opt-in ET recovery UI test with disposable local services and a simulator.

Requires Xcode and Homebrew etserver/etterminal. Uses default Xcode Derived Data.
Run from any directory: python3 scripts/tests/test_et_recovery.py
"""

import asyncio
import base64
import getpass
import json
import os
from pathlib import Path
import plistlib
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


async def run(*arguments, log=None):
    if log:
        with log.open("wb") as output:
            process = await asyncio.create_subprocess_exec(*arguments, cwd=ROOT, stdout=output, stderr=output)
            status = await process.wait()
        if status:
            print(log.read_text(errors="replace")[-8000:], flush=True)
            raise RuntimeError(f"{arguments[0]} failed ({status})")
        return ""
    process = await asyncio.create_subprocess_exec(
        *arguments, cwd=ROOT, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    output, error = await process.communicate()
    if process.returncode:
        raise RuntimeError(f"{arguments[0]} failed ({process.returncode})")
    return output.decode().strip()


def stop_fixture_processes(directory):
    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,command="], text=True).splitlines()
    processes = [row.strip().split(None, 2) for row in rows]
    owned = {int(row[0]) for row in processes if len(row) == 3 and str(directory) in row[2]}
    owned.difference_update({os.getpid(), os.getppid()})
    while True:
        children = {int(row[0]) for row in processes if len(row) == 3 and int(row[1]) in owned}
        if children <= owned:
            break
        owned.update(children)
    for pid in owned:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    time.sleep(0.2)
    for pid in owned:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


async def test(directory):
    device = None
    connections = set()
    handlers = set()
    tasks = []
    server = None
    try:
        for name in ("host-key", "client-key"):
            await run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(directory / name))
        ssh_port, et_port = port(), port()
        router = directory / "router.sock"
        dispatch = directory / "dispatch.py"
        extra = " --serverfifo=" + shlex.quote(str(router)) + " --logdir=" + shlex.quote(str(directory))
        dispatch.write_text(
            f"#!{sys.executable}\nimport os\n"
            "command = os.environ.get('SSH_ORIGINAL_COMMAND', '')\n"
            f"command = command.replace('etterminal --logtostdout', 'etterminal --logtostdout' + {extra!r})\n"
            "os.execv('/bin/sh', ['sh', '-c', command])\n"
        )
        dispatch.chmod(0o700)
        config = directory / "sshd.conf"
        config.write_text(
            f"Port {ssh_port}\nListenAddress 127.0.0.1\nHostKey {directory}/host-key\n"
            f"AuthorizedKeysFile {directory}/client-key.pub\nPidFile {directory}/sshd.pid\n"
            "StrictModes no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\n"
            f"AllowUsers {getpass.getuser()}\nForceCommand {shlex.quote(str(dispatch))}\n"
        )
        et_config = directory / "et.cfg"
        et_config.write_text("[Debug]\ntelemetry=false\n")
        for name, command in (
            ("ssh", ["/usr/sbin/sshd", "-D", "-e", "-f", str(config)]),
            ("et", ["/opt/homebrew/bin/etserver", "--cfgfile", str(et_config), "--port", str(et_port),
                    "--bindip", "127.0.0.1", "--serverfifo", str(router), "--logdir", str(directory), "--logtostdout"]),
        ):
            with (directory / f"{name}.log").open("wb") as output:
                process = await asyncio.create_subprocess_exec(*command, stdout=output, stderr=output)
            tasks.append(process)
        for _ in range(100):
            if router.exists():
                break
            if any(process.returncode is not None for process in tasks):
                raise RuntimeError("Local server failed to start")
            await asyncio.sleep(0.05)
        else:
            raise RuntimeError("ET router did not start")

        async def proxy(reader, writer):
            upstream = None
            copies = []
            handlers.add(asyncio.current_task())
            try:
                remote, upstream = await asyncio.open_connection("127.0.0.1", et_port)
                connections.update((writer, upstream))

                async def copy(source, destination):
                    while data := await source.read(65536):
                        destination.write(data)
                        await destination.drain()

                copies = [asyncio.create_task(copy(reader, upstream)), asyncio.create_task(copy(remote, writer))]
                _, pending = await asyncio.wait(copies, return_when=asyncio.FIRST_COMPLETED)
                for task in pending:
                    task.cancel()
                await asyncio.gather(*copies, return_exceptions=True)
            finally:
                for task in copies:
                    task.cancel()
                await asyncio.gather(*copies, return_exceptions=True)
                for connection in (writer, upstream):
                    if connection:
                        connections.discard(connection)
                        connection.close()
                handlers.discard(asyncio.current_task())

        server = await asyncio.start_server(proxy, "127.0.0.1", 0)
        proxy_port = server.sockets[0].getsockname()[1]
        drop_file = directory / "drop"

        async def watch_drop():
            while True:
                if drop_file.exists():
                    drop_file.unlink()
                    for connection in list(connections):
                        connection.close()
                    print("Dropped ET sockets; server shells remain running", flush=True)
                await asyncio.sleep(0.05)

        watch = asyncio.create_task(watch_drop())
        handlers.add(watch)
        shell = directory / "shell.sh"
        shell.write_text(
            "#!/bin/bash\nstty -echo -icanon min 1 time 0\ncount=0\n"
            "emit() {\n"
            f"  mkdir -p {shlex.quote(str(directory))}/ET_UI_$$_$count\n"
            f"  cd {shlex.quote(str(directory))}/ET_UI_$$_$count || exit 1\n"
            "  printf '\033]7;file://localhost%s\007' \"$PWD\"\n}\n"
            "emit\nwhile IFS= read -r -n 1 key; do\n"
            "  if [[ $key == x ]]; then count=$((count + 1)); emit; fi\ndone\n"
        )
        runtimes = json.loads(await run("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
        runtime = next(value for value in runtimes if value["isAvailable"] and "SimRuntime.iOS-" in value["identifier"])
        device = await run("xcrun", "simctl", "create", "VVTerm ET Regression", "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", runtime["identifier"])
        await run("xcrun", "simctl", "boot", device)
        await run("xcrun", "simctl", "bootstatus", device, "-b")
        print("Building the iOS test bundle with default Derived Data", flush=True)
        await run("xcodebuild", "-project", "VVTerm.xcodeproj", "-scheme", "VVTerm", "-destination", f"platform=iOS Simulator,id={device}",
                  "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile", "build-for-testing", log=directory / "build.log")
        products = Path.home() / "Library/Developer/Xcode/DerivedData"
        candidates = sorted(products.glob("VVTerm-*/Build/Products/VVTerm_VVTerm_iphonesimulator*.xctestrun"), key=lambda path: path.stat().st_mtime, reverse=True)
        original = candidates[0]
        spec = plistlib.loads(original.read_bytes())

        def paths(value):
            if isinstance(value, str):
                return value.replace("__TESTROOT__", str(original.parent))
            if isinstance(value, list):
                return [paths(child) for child in value]
            if isinstance(value, dict):
                return {key: paths(child) for key, child in value.items()}
            return value

        spec = paths(spec)
        target = next(target for config in spec["TestConfigurations"] for target in config["TestTargets"] if target["BlueprintName"] == "VVTermUITests")
        target.setdefault("EnvironmentVariables", {}).update(VVTERM_ET_UI_INTEGRATION="1", VVTERM_ET_UI_DROP_FILE=str(drop_file))
        await run("xcrun", "simctl", "install", device, target["UITargetAppPath"])
        fingerprint = (await run("ssh-keygen", "-lf", str(directory / "host-key.pub"), "-E", "sha256")).split()[1]
        for key, value, kind in (
            ("sshUsername", getpass.getuser(), "-string"),
            ("sshPrivateKeyBase64", base64.b64encode((directory / "client-key").read_bytes()).decode(), "-string"),
            ("sshHostFingerprint", fingerprint, "-string"), ("sshHostKeyType", "6", "-int"),
            ("etSSHPort", str(ssh_port), "-int"), ("etPort", str(proxy_port), "-int"),
            ("etRecoveryStartupCommand", "exec /bin/bash " + shlex.quote(str(shell)), "-string"),
        ):
            await run("xcrun", "simctl", "spawn", device, "defaults", "write", "app.vivy.vvterm.dev199-ui-test", key, kind, value)
        configured = directory / "ET.xctestrun"
        configured.write_bytes(plistlib.dumps(spec))
        print("Testing background drops, tab changes, and manual reconnect", flush=True)
        await run("xcodebuild", "test-without-building", "-xctestrun", str(configured), "-destination", f"platform=iOS Simulator,id={device}",
                  "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-only-testing:VVTermUITests/EternalTerminalRecoveryUITests", log=directory / "test.log")
        if " skipped " in (directory / "test.log").read_text(errors="replace"):
            raise RuntimeError("ET recovery test was skipped")
        print("ET recovery UI test passed", flush=True)
    finally:
        if server:
            server.close()
            await server.wait_closed()
        for connection in list(connections):
            connection.close()
        for handler in list(handlers):
            handler.cancel()
        await asyncio.gather(*handlers, return_exceptions=True)
        if device:
            for action in ("shutdown", "delete"):
                process = await asyncio.create_subprocess_exec(
                    "xcrun", "simctl", action, device,
                    stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL
                )
                await process.wait()
        stop_fixture_processes(directory)
        await asyncio.gather(*(process.wait() for process in tasks))


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="vvterm-et-ui-") as temporary:
        asyncio.run(test(Path(temporary)))
