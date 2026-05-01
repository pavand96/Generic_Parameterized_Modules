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
        description="Run gearbox cocotb regressions with random IN_DB/OUT_DB values."
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
        "--min-db",
        type=int,
        default=1,
        help="minimum byte width to test",
    )
    parser.add_argument(
        "--max-db",
        type=int,
        default=10,
        help="maximum byte width to test",
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
    if args.min_db < 1:
        parser.error("--min-db must be at least 1")
    if args.max_db < args.min_db:
        parser.error("--max-db must be greater than or equal to --min-db")

    script_dir = Path(__file__).resolve().parent
    seed = args.seed if args.seed is not None else random.randrange(2**32)
    rng = random.Random(seed)
    failures = []

    print(f"seed={seed}", flush=True)

    for run_idx in range(1, args.iterations + 1):
        in_db = rng.randint(args.min_db, args.max_db)
        out_db = rng.randint(args.min_db, args.max_db)
        label = f"[{run_idx}/{args.iterations}] IN_DB={in_db} OUT_DB={out_db}"
        print(f"{label}: running", flush=True)

        clean = run_command(["make", "clean"], cwd=script_dir)
        if clean.returncode != 0:
            print_failure(f"{label} clean", clean)
            return clean.returncode

        make = run_command(
            [
                "make",
                f"IN_DB={in_db}",
                f"OUT_DB={out_db}",
                f"WAVES={args.waves}",
            ],
            cwd=script_dir,
        )

        if make.returncode == 0:
            print(f"{label}: PASS", flush=True)
            continue

        print_failure(label, make)
        failures.append((in_db, out_db))
        if not args.keep_going:
            break

    if failures:
        print("\nFailing parameter pairs:")
        for in_db, out_db in failures:
            print(f"  IN_DB={in_db} OUT_DB={out_db}")
        return 1

    print(f"\nPASS: {args.iterations} randomized gearbox parameter runs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
