#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

TIMEOUT = 30.0


def fail(message):
    raise RuntimeError(message)


def wait_path(path, timeout=TIMEOUT):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.01)
    fail(f"timed out waiting for {path}")


def read_json(path):
    wait_path(path)
    return json.loads(path.read_text())


def touch(path):
    path.write_bytes(b"go\n")


def prepare_root(root):
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root.chmod(0o700)


def command(executable, name, *args):
    return [str(executable), name, *map(str, args)]


def run_json(executable, name, *args):
    argv = command(executable, name, *args)
    completed = subprocess.run(argv, text=True, capture_output=True, timeout=TIMEOUT)
    if completed.returncode != 0:
        fail(f"{name} failed rc={completed.returncode}: {completed.stderr.strip()}")
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        fail(f"{name} did not emit one JSON result: {error}: {completed.stdout!r}")
    return completed, payload


def spawn(executable, name, *args):
    argv = command(executable, name, *args)
    process = subprocess.Popen(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return process, argv


def finish(process, label, timeout=TIMEOUT):
    stdout, stderr = process.communicate(timeout=timeout)
    if process.returncode != 0:
        fail(f"{label} failed rc={process.returncode}: {stderr.strip()}")
    return {"pid": process.pid, "exitCode": process.returncode, "stdout": stdout.strip()}


def terminate(process):
    if process.poll() is None:
        process.terminate()
    try:
        stdout, stderr = process.communicate(timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate(timeout=TIMEOUT)
    return {"pid": process.pid, "exitCode": process.returncode, "stdout": stdout.strip(), "stderr": stderr.strip()}



def spawn_external_gate_writer(barrier, gate_ready, retirement_acquired):
    script = r'''\
import fcntl, json, os, sys
descriptor = os.open(sys.argv[1], os.O_RDWR)
fcntl.lockf(descriptor, fcntl.LOCK_EX, 1, 0, os.SEEK_SET)
with open(sys.argv[2], "w", encoding="utf-8") as marker:
    json.dump({"phase": "gate-held"}, marker)
    marker.write("\n")
fcntl.lockf(descriptor, fcntl.LOCK_EX, 1, 1, os.SEEK_SET)
with open(sys.argv[3], "w", encoding="utf-8") as marker:
    json.dump({"phase": "retirement-acquired"}, marker)
    marker.write("\n")
os.close(descriptor)
'''
    argv = ["/usr/bin/python3", "-c", script, str(barrier), str(gate_ready), str(retirement_acquired)]
    return subprocess.Popen(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE), argv

def assert_phase(payload, phase, count=None):
    if payload.get("phase") != phase:
        fail(f"expected phase {phase}, got {payload}")
    if count is not None and payload.get("readerCount") != count:
        fail(f"expected readerCount {count}, got {payload}")


def scenario_local_refcount(executable, root):
    prepare_root(root)
    barrier = root / "retirement.lock"
    ready = root / "ready.json"
    release_one = root / "release-one"
    after_one = root / "after-one.json"
    release_two = root / "release-two"
    after_two = root / "after-two.json"
    process, argv = spawn(
        executable,
        "multiprocess-retirement-local-refcount",
        "--barrier", barrier,
        "--ready", ready,
        "--release-one", release_one,
        "--after-one", after_one,
        "--release-two", release_two,
        "--after-two", after_two,
    )
    try:
        first = read_json(ready)
        assert_phase(first, "two-readers-held", 2)
        touch(release_one)
        second = read_json(after_one)
        assert_phase(second, "one-reader-remains", 1)
        touch(release_two)
        third = read_json(after_two)
        assert_phase(third, "all-readers-released", 0)
        terminal = finish(process, "local-refcount")
    finally:
        if process.poll() is None:
            terminate(process)
    return {"argv": argv, "pid": terminal["pid"], "exitCode": terminal["exitCode"], "states": [first, second, third]}


def scenario_writer_state(executable, root):
    prepare_root(root)
    names = [
        "ready", "begin", "pending", "try-reader", "try-reader-result",
        "finish-before-release", "finish-before-result", "release-reader", "reader-released",
        "finish-after-release", "finish-after-result", "release-writer", "writer-released",
    ]
    p = {name: root / (name + (".json" if name in {
        "ready", "pending", "try-reader-result", "finish-before-result", "reader-released",
        "finish-after-result", "writer-released",
    } else "")) for name in names}
    barrier = root / "retirement.lock"
    process, argv = spawn(
        executable,
        "multiprocess-retirement-local-writer-state",
        "--barrier", barrier,
        "--ready", p["ready"],
        "--begin", p["begin"],
        "--pending", p["pending"],
        "--try-reader", p["try-reader"],
        "--try-reader-result", p["try-reader-result"],
        "--finish-before-release", p["finish-before-release"],
        "--finish-before-result", p["finish-before-result"],
        "--release-reader", p["release-reader"],
        "--reader-released", p["reader-released"],
        "--finish-after-release", p["finish-after-release"],
        "--finish-after-result", p["finish-after-result"],
        "--release-writer", p["release-writer"],
        "--writer-released", p["writer-released"],
    )
    try:
        ready = read_json(p["ready"])
        assert_phase(ready, "reader-held", 1)
        touch(p["begin"])
        pending = read_json(p["pending"])
        assert_phase(pending, "writer-pending-gate-held", 1)
        touch(p["try-reader"])
        reader_pending = read_json(p["try-reader-result"])
        assert_phase(reader_pending, "reader-while-writer-pending", 1)
        if reader_pending.get("acquired") is not False:
            fail(f"late local reader was admitted: {reader_pending}")
        touch(p["finish-before-release"])
        finish_before = read_json(p["finish-before-result"])
        assert_phase(finish_before, "finish-before-reader-release", 1)
        if finish_before.get("acquired") is not False:
            fail(f"writer bypassed admitted reader: {finish_before}")
        touch(p["release-reader"])
        released = read_json(p["reader-released"])
        assert_phase(released, "reader-released", 0)
        touch(p["finish-after-release"])
        active = read_json(p["finish-after-result"])
        assert_phase(active, "writer-active", 0)
        if active.get("acquired") is not True or active.get("readerAdmissionWhileWriterActive") is not False:
            fail(f"writer-active turnstile invariant failed: {active}")
        touch(p["release-writer"])
        writer_released = read_json(p["writer-released"])
        assert_phase(writer_released, "writer-released", 0)
        terminal = finish(process, "local-writer-state")
    finally:
        if process.poll() is None:
            terminate(process)
    return {
        "argv": argv,
        "pid": terminal["pid"],
        "exitCode": terminal["exitCode"],
        "pending": pending,
        "readerWhilePending": reader_pending,
        "finishBeforeReaderRelease": finish_before,
        "writerActive": active,
    }


def seed(executable, root):
    completed, payload = run_json(executable, "multiprocess-retirement-seed", "--root", root, "--label", "a")
    if payload.get("profile") != "segmentedDirectoryHeadV3" or payload.get("baseKind") != "baseBinaryV2":
        fail(f"unexpected seed profile: {payload}")
    if payload.get("payloadPathExists") is not True or payload.get("payloadExact") is not True or payload.get("digestExact") is not True:
        fail(f"seed payload invariant failed: {payload}")
    return {"pid": None, "exitCode": completed.returncode, "result": payload}


def turnstile_paths(root):
    return {
        "barrier": root / "retirement.lock",
        "reader_ready": root / "reader-ready.json",
        "open_signal": root / "open-signal",
        "fd_opened": root / "fd-opened.json",
        "read_signal": root / "read-signal",
        "reader_result": root / "reader-result.json",
        "gate_marker": root / "writer-gate.json",
        "retirement_state": root / "writer-retirement.json",
        "writer_result": root / "writer-result.json",
    }


def start_turnstile_reader(executable, store_root, paths):
    return spawn(
        executable,
        "multiprocess-retirement-turnstile-reader",
        "--root", store_root,
        "--label", "a",
        "--barrier", paths["barrier"],
        "--ready", paths["reader_ready"],
        "--open-signal", paths["open_signal"],
        "--fd-opened", paths["fd_opened"],
        "--read-signal", paths["read_signal"],
        "--result", paths["reader_result"],
    )


def assert_turnstile_reader_ready(paths):
    ready = read_json(paths["reader_ready"])
    if ready.get("retirementSharedHeld") is not True or ready.get("gateReleased") is not True:
        fail(f"reader admission invariant failed: {ready}")
    return ready


def start_turnstile_writer(executable, store_root, paths):
    return spawn(
        executable,
        "multiprocess-retirement-turnstile-remove",
        "--root", store_root,
        "--label", "a",
        "--barrier", paths["barrier"],
        "--gate-acquired", paths["gate_marker"],
        "--retirement-state", paths["retirement_state"],
        "--result", paths["writer_result"],
    )


def assert_turnstile_writer_pending(executable, paths):
    gate = read_json(paths["gate_marker"])
    if gate.get("phase") != "gate-acquired":
        fail(f"writer gate marker invalid: {gate}")
    _, late_reader = run_json(
        executable,
        "multiprocess-retirement-turnstile-check",
        "--barrier", paths["barrier"],
        "--range", "gate",
        "--kind", "shared",
    )
    if late_reader.get("immediatelyAvailable") is not False:
        fail(f"writer gate admitted a late reader: {late_reader}")
    retirement = read_json(paths["retirement_state"])
    if retirement.get("phase") != "retirement-would-block":
        fail(f"writer did not wait for admitted reader: {retirement}")
    return gate, late_reader, retirement


def handoff_turnstile_descriptor(paths):
    touch(paths["open_signal"])
    opened = read_json(paths["fd_opened"])
    if (
        opened.get("descriptorValidated") is not True
        or opened.get("sharedBarrierReleased") is not True
        or opened.get("payloadPathExistsAtOpen") is not True
    ):
        fail(f"reader descriptor handoff failed: {opened}")
    return opened


def complete_turnstile_writer(writer, paths):
    payload = read_json(paths["writer_result"])
    terminal = finish(writer, "turnstile-writer")
    if payload.get("retirementInitiallyWouldBlock") is not True or payload.get("retirementEventuallyAcquired") is not True:
        fail(f"writer retirement transition failed: {payload}")
    if payload.get("logicalMissAfterRemove") is not True or payload.get("payloadPathExistsAfterRemove") is not False:
        fail(f"writer did not retire payload: {payload}")
    return payload, terminal


def complete_turnstile_reader(reader, paths):
    touch(paths["read_signal"])
    payload = read_json(paths["reader_result"])
    terminal = finish(reader, "turnstile-reader")
    if payload.get("payloadPathExistsAfterWriter") is not False:
        fail(f"payload path still exists after writer: {payload}")
    if payload.get("payloadExact") is not True or payload.get("digestExact") is not True:
        fail(f"open descriptor did not preserve exact bytes after unlink: {payload}")
    return payload, terminal


def scenario_turnstile(executable, root):
    prepare_root(root)
    store_root = root / "store"
    seeded = seed(executable, store_root)
    paths = turnstile_paths(root)
    reader, reader_argv = start_turnstile_reader(executable, store_root, paths)
    writer = None
    try:
        assert_turnstile_reader_ready(paths)
        writer, writer_argv = start_turnstile_writer(executable, store_root, paths)
        gate, late_reader, retirement = assert_turnstile_writer_pending(executable, paths)
        opened = handoff_turnstile_descriptor(paths)
        writer_payload, writer_terminal = complete_turnstile_writer(writer, paths)
        reader_payload, reader_terminal = complete_turnstile_reader(reader, paths)
    finally:
        if writer is not None and writer.poll() is None:
            terminate(writer)
        if reader.poll() is None:
            terminate(reader)

    return {
        "seed": seeded,
        "readerArgv": reader_argv,
        "readerPid": reader_terminal["pid"],
        "writerArgv": writer_argv,
        "writerPid": writer_terminal["pid"],
        "gate": gate,
        "lateReaderCheck": late_reader,
        "retirement": retirement,
        "descriptorOpened": opened,
        "writerResult": writer_payload,
        "readerResult": reader_payload,
    }


def scenario_process_exit(executable, root):
    prepare_root(root)
    store_root = root / "store"
    seeded = seed(executable, store_root)
    barrier = root / "retirement.lock"
    ready = root / "reader-ready.json"
    open_signal = root / "never-open"
    fd_opened = root / "never-fd-opened.json"
    read_signal = root / "never-read"
    result = root / "never-result.json"
    holder, argv = spawn(
        executable,
        "multiprocess-retirement-turnstile-reader",
        "--root", store_root,
        "--label", "a",
        "--barrier", barrier,
        "--ready", ready,
        "--open-signal", open_signal,
        "--fd-opened", fd_opened,
        "--read-signal", read_signal,
        "--result", result,
    )
    try:
        held = read_json(ready)
        if held.get("retirementSharedHeld") is not True:
            fail(f"holder did not acquire retirement lease: {held}")
        _, before = run_json(
            executable,
            "multiprocess-retirement-check",
            "--barrier", barrier,
            "--kind", "exclusive",
        )
        if before.get("immediatelyAvailable") is not False:
            fail(f"exclusive lock unexpectedly available before child exit: {before}")
        terminal = terminate(holder)
        _, after = run_json(
            executable,
            "multiprocess-retirement-check",
            "--barrier", barrier,
            "--kind", "exclusive",
        )
        if after.get("immediatelyAvailable") is not True:
            fail(f"record lock survived child exit: {after}")
    finally:
        if holder.poll() is None:
            terminate(holder)
    return {
        "seed": seeded,
        "holderArgv": argv,
        "holderPid": terminal["pid"],
        "holderExitCode": terminal["exitCode"],
        "beforeExit": before,
        "afterExit": after,
    }



def scenario_external_writer_local_coordinator(executable, root, waiter):
    prepare_root(root)
    barrier = root / "retirement.lock"
    swift_ready = root / "swift-ready.json"
    start_waiter = root / "start-waiter"
    waiter_started = root / "waiter-started"
    release_reader = root / "release-reader"
    reader_released = root / "reader-released.json"
    waiter_done = root / "waiter-done.json"
    final_state = root / "final-state.json"
    writer_gate = root / "external-writer-gate.json"
    writer_retirement = root / "external-writer-retirement.json"

    swift, swift_argv = spawn(
        executable,
        "multiprocess-retirement-external-coordinator",
        "--barrier", barrier,
        "--waiter", waiter,
        "--ready", swift_ready,
        "--start", start_waiter,
        "--waiter-started", waiter_started,
        "--release", release_reader,
        "--released", reader_released,
        "--waiter-done", waiter_done,
        "--final", final_state,
    )
    writer = None
    try:
        ready = read_json(swift_ready)
        assert_phase(ready, f"external-{waiter}-initial-reader-held", 1)

        writer, writer_argv = spawn_external_gate_writer(
            barrier, writer_gate, writer_retirement
        )
        gate = read_json(writer_gate)
        if gate.get("phase") != "gate-held":
            fail(f"external writer did not acquire gate: {gate}")

        touch(start_waiter)
        wait_path(waiter_started)
        touch(release_reader)
        released = read_json(reader_released)
        assert_phase(released, f"external-{waiter}-initial-reader-released", 0)

        retirement = read_json(writer_retirement)
        if retirement.get("phase") != "retirement-acquired":
            fail(f"external writer did not acquire retirement: {retirement}")
        writer_terminal = finish(writer, f"external-writer-{waiter}")
        writer = None

        waiter_result = read_json(waiter_done)
        assert_phase(waiter_result, f"external-{waiter}-waiter-done", 0)
        final = read_json(final_state)
        assert_phase(final, f"external-{waiter}-final-clean", 0)
        swift_terminal = finish(swift, f"external-coordinator-{waiter}")
    finally:
        if writer is not None and writer.poll() is None:
            terminate(writer)
        if swift.poll() is None:
            terminate(swift)

    return {
        "waiter": waiter,
        "swiftArgv": swift_argv,
        "swiftPid": swift_terminal["pid"],
        "swiftExitCode": swift_terminal["exitCode"],
        "writerArgv": writer_argv,
        "writerPid": writer_terminal["pid"],
        "writerExitCode": writer_terminal["exitCode"],
        "gate": gate,
        "initialReaderReleased": released,
        "retirement": retirement,
        "waiterResult": waiter_result,
        "final": final,
    }

def negative(executable, label, name, *args):
    argv = command(executable, name, *args)
    completed = subprocess.run(argv, text=True, capture_output=True, timeout=TIMEOUT)
    if completed.returncode == 0:
        fail(f"negative {label} unexpectedly succeeded: {completed.stdout!r}")
    if completed.stdout.strip():
        try:
            json.loads(completed.stdout)
        except json.JSONDecodeError:
            pass
        else:
            fail(f"negative {label} emitted success-like JSON: {completed.stdout!r}")
    return {"label": label, "argv": argv, "exitCode": completed.returncode}


def scenario_negative_reachability(executable, root):
    prepare_root(root)
    barrier = root / "negative.lock"
    store_root = root / "negative-store"
    return [
        negative(executable, "seed-missing-label", "multiprocess-retirement-seed", "--root", store_root),
        negative(executable, "check-missing-kind", "multiprocess-retirement-check", "--barrier", barrier),
        negative(executable, "reader-missing-signals", "multiprocess-retirement-turnstile-reader", "--root", store_root, "--label", "a"),
        negative(executable, "writer-missing-label", "multiprocess-retirement-turnstile-remove", "--root", store_root, "--barrier", barrier),
        negative(executable, "external-coordinator-missing-args", "multiprocess-retirement-external-coordinator", "--waiter", "reader"),
    ]


def main():
    parser = argparse.ArgumentParser(description="Independent-process Akashic retirement-lease oracle")
    parser.add_argument("--executable", required=True, help="Path to an already-built AkashicResourceProbe executable")
    args = parser.parse_args()
    executable = Path(args.executable).resolve()
    if not executable.is_file() or not os.access(executable, os.X_OK):
        fail(f"AkashicResourceProbe executable is not executable: {executable}")

    with tempfile.TemporaryDirectory(prefix="akashic-retirement-lease-") as temp:
        base = Path(temp)
        report = {
            "schemaVersion": 1,
            "oracle": "independent-os-process-retirement-lease-v1",
            "executable": str(executable),
            "scenarios": {
                "S1-local-refcount": scenario_local_refcount(executable, base / "s1"),
                "S2-writer-state": scenario_writer_state(executable, base / "s2"),
                "S3-turnstile-unlink": scenario_turnstile(executable, base / "s3"),
                "S4-process-exit-release": scenario_process_exit(executable, base / "s4"),
                "S5-command-reachability-negatives": scenario_negative_reachability(executable, base / "s5"),
                "S6-external-writer-local-coordinator": {
                    "reader": scenario_external_writer_local_coordinator(executable, base / "s6-reader", "reader"),
                    "writer": scenario_external_writer_local_coordinator(executable, base / "s6-writer", "writer"),
                },
            },
        }
        print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
