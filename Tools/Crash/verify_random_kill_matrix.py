#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import select
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

KILL_SIGNAL = signal.SIGKILL


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_line_with_timeout(process: subprocess.Popen[bytes], timeout: float) -> bytes:
    assert process.stdout is not None
    readable, _, _ = select.select([process.stdout], [], [], timeout)
    if not readable:
        return b""
    return process.stdout.readline()


def inspect(binary: Path, root: Path, payload_bytes: int) -> tuple[dict[str, object] | None, str]:
    completed = subprocess.run(
        [str(binary), "inspect-random", str(root), str(payload_bytes)],
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    if completed.returncode != 0:
        return None, f"inspect exit={completed.returncode} stderr={completed.stderr[-500:]}"
    try:
        return json.loads(completed.stdout), ""
    except json.JSONDecodeError as error:
        return None, f"invalid inspect JSON: {error}"


def run_case(
    *,
    binary: Path,
    root: Path,
    payload_bytes: int,
    delay_microseconds: int,
    mode: str,
) -> tuple[dict[str, object] | None, str]:
    prewrite_delay = 500_000 if mode == "anchored-miss" else 0
    process = subprocess.Popen(
        [
            str(binary),
            "random-crash",
            str(root),
            str(payload_bytes),
            str(prewrite_delay),
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    started = time.monotonic_ns()
    ready = read_line_with_timeout(process, 15)
    if ready != b"ready\n":
        stderr = process.stderr.read().decode(errors="replace") if process.stderr else ""
        process.kill()
        process.wait(timeout=5)
        return None, f"probe did not become ready: line={ready!r} stderr={stderr[-500:]}"

    assert process.stdin is not None
    process.stdin.write(b"x")
    process.stdin.flush()
    if mode == "anchored-hit":
        committed = read_line_with_timeout(process, 30)
        if committed != b"committed\n":
            process.kill()
            _, stderr = process.communicate(timeout=5)
            return None, (
                f"probe did not publish anchored hit: line={committed!r} "
                f"stderr={stderr.decode(errors='replace')[-500:]}"
            )
    elif delay_microseconds > 0:
        time.sleep(delay_microseconds / 1_000_000)

    os.kill(process.pid, KILL_SIGNAL)
    _, stderr = process.communicate(timeout=10)
    elapsed = time.monotonic_ns() - started
    if process.returncode != -KILL_SIGNAL:
        return None, (
            f"expected SIGKILL return {-KILL_SIGNAL}, got {process.returncode}; "
            f"stderr={stderr.decode(errors='replace')[-500:]}"
        )

    observation, error = inspect(binary, root, payload_bytes)
    if observation is None:
        return None, error
    disposition = observation.get("disposition")
    if disposition not in {"hit", "miss"}:
        return None, f"invalid recovered disposition: {disposition!r}"
    if mode == "anchored-miss" and disposition != "miss":
        return None, f"anchored miss recovered as {disposition}"
    if mode == "anchored-hit" and disposition != "hit":
        return None, f"anchored hit recovered as {disposition}"
    expected_blob_count = 1 if disposition == "hit" else 0
    if observation.get("blobCount") != expected_blob_count:
        return None, (
            f"disposition={disposition} expected blobCount={expected_blob_count}, "
            f"got {observation.get('blobCount')}"
        )
    if observation.get("temporaryCount") != 0:
        return None, f"temporary files remained: {observation.get('temporaryCount')}"
    return {
        "mode": mode,
        "delayMicroseconds": delay_microseconds,
        "observedDisposition": disposition,
        "blobCount": observation.get("blobCount"),
        "temporaryCount": observation.get("temporaryCount"),
        "manifestExists": observation.get("manifestExists"),
        "killSignal": KILL_SIGNAL,
        "elapsedNanoseconds": elapsed,
    }, ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--random-cases", type=int, default=24)
    parser.add_argument("--payload-bytes", type=int, default=8 * 1024 * 1024)
    parser.add_argument("--maximum-delay-microseconds", type=int, default=10_000)
    parser.add_argument("--seed", type=int, default=0xA5A51C)
    args = parser.parse_args()

    binary = args.binary.resolve()
    if not binary.is_file():
        raise FileNotFoundError(binary)
    if (
        args.rounds < 1
        or args.random_cases < 1
        or args.payload_bytes < 1
        or args.maximum_delay_microseconds < 1
    ):
        raise ValueError("rounds, random cases, payload bytes and maximum delay must be positive")

    errors: list[str] = []
    cases: list[dict[str, object]] = []
    rounds: list[dict[str, object]] = []
    global_index = 0
    for round_index in range(args.rounds):
        round_seed = (args.seed + round_index * 0x9E3779B1) & 0xFFFFFFFF
        generator = random.Random(round_seed)
        schedule = [
            ("anchored-miss", 0),
            ("anchored-hit", 0),
            *[
                ("random", generator.randrange(args.maximum_delay_microseconds + 1))
                for _ in range(args.random_cases)
            ],
        ]
        round_cases: list[dict[str, object]] = []
        round_errors: list[str] = []
        for index, (mode, delay) in enumerate(schedule):
            with tempfile.TemporaryDirectory(prefix="akashic-random-kill-") as temporary:
                case, error = run_case(
                    binary=binary,
                    root=Path(temporary) / "store",
                    payload_bytes=args.payload_bytes,
                    delay_microseconds=delay,
                    mode=mode,
                )
            if case is None:
                message = (
                    f"round {round_index} case {index} "
                    f"({mode}, delay={delay}): {error}"
                )
                errors.append(message)
                round_errors.append(message)
            else:
                case["round"] = round_index
                case["roundSeed"] = round_seed
                case["indexWithinRound"] = index
                case["index"] = global_index
                cases.append(case)
                round_cases.append(case)
            global_index += 1
        round_hit_count = sum(
            case["observedDisposition"] == "hit" for case in round_cases
        )
        round_miss_count = sum(
            case["observedDisposition"] == "miss" for case in round_cases
        )
        rounds.append(
            {
                "round": round_index,
                "seed": round_seed,
                "caseCount": len(round_cases),
                "hitCount": round_hit_count,
                "missCount": round_miss_count,
                "status": "failed" if round_errors else "passed",
                "errors": round_errors,
            }
        )

    hit_count = sum(case["observedDisposition"] == "hit" for case in cases)
    miss_count = sum(case["observedDisposition"] == "miss" for case in cases)
    random_cases = [case for case in cases if case["mode"] == "random"]
    random_hit_count = sum(
        case["observedDisposition"] == "hit" for case in random_cases
    )
    random_miss_count = sum(
        case["observedDisposition"] == "miss" for case in random_cases
    )
    if hit_count == 0:
        errors.append("campaign observed no complete committed state")
    if miss_count == 0:
        errors.append("campaign observed no complete pre-publication state")
    if random_hit_count == 0:
        errors.append("random samples observed no complete committed state")
    if random_miss_count == 0:
        errors.append("random samples observed no complete pre-publication state")
    scheduled_case_count = args.rounds * (args.random_cases + 2)
    result = {
        "schemaVersion": 2,
        "matrixID": "AKASHIC-FILE-BLOB-RANDOM-KILL-CAMPAIGN-V2",
        "binarySHA256": sha256(binary),
        "seed": args.seed,
        "roundCount": args.rounds,
        "randomCasesPerRound": args.random_cases,
        "randomCaseCount": len(random_cases),
        "scheduledCaseCount": scheduled_case_count,
        "caseCount": len(cases),
        "payloadBytes": args.payload_bytes,
        "maximumDelayMicroseconds": args.maximum_delay_microseconds,
        "hitCount": hit_count,
        "missCount": miss_count,
        "randomHitCount": random_hit_count,
        "randomMissCount": random_miss_count,
        "processCrashClaim": len(cases) == scheduled_case_count and not errors,
        "powerLossClaim": False,
        "status": "failed" if errors else "passed",
        "rounds": rounds,
        "cases": cases,
        "errors": errors,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        "Akashic random kill campaign: "
        f"rounds={args.rounds} cases={len(cases)}/{scheduled_case_count} "
        f"hit={hit_count} miss={miss_count} "
        f"randomHit={random_hit_count} randomMiss={random_miss_count} "
        f"errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
