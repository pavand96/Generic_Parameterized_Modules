#!/usr/bin/env python3
import argparse
import random
import subprocess
import sys
from pathlib import Path


def run_command(cmd, cwd):
    return subprocess.run(
        cmd,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )


def print_failure(name, result):
    print(f"\n{name} failed with exit code {result.returncode}")
    print("-" * 80)
    print(result.stdout.rstrip())
    print("-" * 80)


def main():
    parser = argparse.ArgumentParser(
        description="Run gearbox cocotb regressions with random IN_CHUNKS_PER_BEAT/OUT_CHUNKS_PER_BEAT values."
    )
    parser.add_argument(
        "-n",
        "--iterations",
        type=int,
        default=20,
        help="number of random parameter pairs to test",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=None,
        help="random seed; printed so failing runs can be reproduced",
    )
    parser.add_argument(
        "--min-chunks-per-beat",
        dest="min_chunks_per_beat",
        type=int,
        default=1,
        help="minimum chunks per beat to test",
    )
    parser.add_argument(
        "--max-chunks-per-beat",
        dest="max_chunks_per_beat",
        type=int,
        default=10,
        help="maximum chunks per beat to test",
    )
    parser.add_argument(
        "--chunk-width",
        type=int,
        default=8,
        help="chunk width in bits",
    )
    parser.add_argument(
        "--keep-going",
        action="store_true",
        help="continue after failures and report all failing parameter pairs",
    )
    parser.add_argument(
        "--waves",
        choices=("0", "1"),
        default="0",
        help="set WAVES for the cocotb Makefile",
    )
    args = parser.parse_args()

    if args.iterations < 1:
        parser.error("--iterations must be at least 1")
    if args.min_chunks_per_beat < 1:
        parser.error("--min-chunks-per-beat must be at least 1")
    if args.max_chunks_per_beat < args.min_chunks_per_beat:
        parser.error(
            "--max-chunks-per-beat must be greater than or equal to "
            "--min-chunks-per-beat"
        )
    if args.chunk_width < 1:
        parser.error("--chunk-width must be at least 1")

    script_dir = Path(__file__).resolve().parent
    seed = args.seed if args.seed is not None else random.randrange(2**32)
    rng = random.Random(seed)
    failures = []

    print(f"seed={seed}", flush=True)

    for run_idx in range(1, args.iterations + 1):
        in_chunks_per_beat = rng.randint(
            args.min_chunks_per_beat,
            args.max_chunks_per_beat,
        )
        out_chunks_per_beat = rng.randint(
            args.min_chunks_per_beat,
            args.max_chunks_per_beat,
        )
        label = (
            f"[{run_idx}/{args.iterations}] "
            f"IN_CHUNKS_PER_BEAT={in_chunks_per_beat} "
            f"OUT_CHUNKS_PER_BEAT={out_chunks_per_beat} "
            f"CHUNK_WIDTH={args.chunk_width}"
        )
        print(f"{label}: running", flush=True)

        clean = run_command(["make", "clean"], cwd=script_dir)
        if clean.returncode != 0:
            print_failure(f"{label} clean", clean)
            return clean.returncode

        make = run_command(
            [
                "make",
                f"IN_CHUNKS_PER_BEAT={in_chunks_per_beat}",
                f"OUT_CHUNKS_PER_BEAT={out_chunks_per_beat}",
                f"CHUNK_WIDTH={args.chunk_width}",
                f"WAVES={args.waves}",
            ],
            cwd=script_dir,
        )

        if make.returncode == 0:
            print(f"{label}: PASS", flush=True)
            continue

        print_failure(label, make)
        failures.append((in_chunks_per_beat, out_chunks_per_beat))
        if not args.keep_going:
            break

    if failures:
        print("\nFailing parameter pairs:")
        for in_chunks_per_beat, out_chunks_per_beat in failures:
            print(
                f"  IN_CHUNKS_PER_BEAT={in_chunks_per_beat} "
                f"OUT_CHUNKS_PER_BEAT={out_chunks_per_beat} "
                f"CHUNK_WIDTH={args.chunk_width}"
            )
        return 1

    print(f"\nPASS: {args.iterations} randomized gearbox parameter runs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
