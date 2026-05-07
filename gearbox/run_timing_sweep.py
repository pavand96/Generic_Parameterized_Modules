#!/usr/bin/env python3
"""Sweep target clock frequencies for a single gearbox width pair.

Synthesizes both the adder (origin/main) and one-hot (current) implementations
across a range of target clock periods, reporting area and critical-path delay
at each point.  Use this to visualise the timing–area Pareto curve for one case
and to determine approximately where the design hits its Fmax.

How timing extraction works
---------------------------
Yosys's abc pass is invoked with '-liberty <lib> -script <abc_script>' where
the abc script hardcodes the target period (picoseconds) and ends with ABC's
'stime' command.  Yosys wraps the script with read_blif/write_blif and prepends
read_lib, so the 'stime' output appears in the tee-captured timing report.  The
critical-path delay is parsed from the line:
    WireLoad = "none"  Gates = ...  Delay = <value> ps  ...

The full-chip area (combinational + sequential) comes from 'stat -liberty'.

Example – SKY130, 24→40 conversion, 200 MHz to 1 GHz in 100 MHz steps:
    python3 run_timing_sweep.py --in-data-width 24 --out-data-width 40

Example – ASAP7, same conversion, 500 MHz to 4 GHz:
    python3 run_timing_sweep.py --in-data-width 24 --out-data-width 40 \\
        --liberty ../../third_party/asap7/asap7sc7p5t_RVT_TT_nldm_merged.lib \\
        --freqs 500,1000,1500,2000,2500,3000,3500,4000 \\
        --build-dir timing_sweep_asap7
"""

import argparse
import concurrent.futures
import csv
import os
import shutil
import subprocess
from pathlib import Path

from gearbox_synth_lib import (
    PDK_CHOICES,
    VARIANTS,
    classify_case,
    make_abc_script,
    make_yosys_script_timing,
    parse_area,
    parse_cell_count,
    parse_check_ok,
    parse_delay_ps,
    pdk_liberty_path,
    prepare_rtl,
    read_common_mux,
    read_variant_rtl,
)


def parse_args():
    repo_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(
        description="Sweep clock frequencies for a single gearbox width pair.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--in-data-width", type=int, default=24)
    parser.add_argument("--out-data-width", type=int, default=40)
    parser.add_argument(
        "--pdk",
        choices=PDK_CHOICES,
        default="sky130",
        help="Target PDK (sets liberty file). Overridden by --liberty.",
    )
    parser.add_argument(
        "--liberty",
        type=Path,
        default=None,
        help="Liberty file path. Overrides --pdk.",
    )
    parser.add_argument(
        "--freqs",
        default="100,200,300,400,500,600,700,800,900,1000",
        help="Comma-separated list of target frequencies in MHz (default SKY130 range).",
    )
    parser.add_argument(
        "--variant",
        choices=("adder", "onehot", "both"),
        default="both",
        help="Which implementation to synthesise.",
    )
    parser.add_argument("--build-dir", type=Path, default=Path("timing_sweep_build"))
    parser.add_argument("--yosys", default=os.environ.get("YOSYS", "yosys"))
    parser.add_argument("--jobs", type=int, default=os.cpu_count())
    parser.add_argument("--rerun", action="store_true", help="Re-run even if results exist.")
    args = parser.parse_args()
    if args.liberty is None:
        args.liberty = pdk_liberty_path(args.pdk, repo_root)
    return args


def _parse_reports(stat_text, timing_text, check_text, period_ps):
    delay_ps = parse_delay_ps(timing_text)
    area = parse_area(stat_text)
    cell_count = parse_cell_count(stat_text)
    check_ok = parse_check_ok(check_text)
    timing_met = delay_ps is not None and delay_ps <= period_ps
    status = "PASS" if (area is not None and check_ok and delay_ps is not None) else "FAIL"
    return delay_ps, area, cell_count, check_ok, timing_met, status


def synthesize_one(task):
    (
        repo_root,
        yosys_bin,
        liberty,
        build_root,
        variant_name,
        rtl_text,
        common_mux_text,
        in_data_width,
        out_data_width,
        target_mhz,
        rerun,
    ) = task

    period_ps = int(round(1e6 / target_mhz))
    case_dir = build_root / variant_name / f"{target_mhz}mhz"
    case_dir.mkdir(parents=True, exist_ok=True)

    rtl_path = case_dir / "gearbox_yosys.sv"
    abc_script_path = case_dir / "abc_timing.script"
    ys_script_path = case_dir / "gearbox_synth.ys"
    netlist_path = case_dir / "gearbox_mapped.v"
    stat_path = case_dir / "gearbox_stat.rpt"
    check_path = case_dir / "gearbox_check.rpt"
    timing_path = case_dir / "gearbox_timing.rpt"
    log_path = case_dir / "yosys.log"

    if not rerun and stat_path.exists() and timing_path.exists() and check_path.exists():
        stat_text = stat_path.read_text(encoding="utf-8")
        timing_text = timing_path.read_text(encoding="utf-8")
        check_text = check_path.read_text(encoding="utf-8")
        delay_ps, area, cell_count, check_ok, timing_met, status = _parse_reports(
            stat_text, timing_text, check_text, period_ps
        )
        return _make_row(
            variant_name, in_data_width, out_data_width, target_mhz, period_ps,
            delay_ps, area, cell_count, check_ok, timing_met, status, log_path,
        )

    generated_rtl = prepare_rtl(
        variant_name, rtl_text, common_mux_text, in_data_width, out_data_width
    )
    rtl_path.write_text(generated_rtl, encoding="utf-8")
    abc_script_path.write_text(make_abc_script(period_ps), encoding="utf-8")
    ys_script_path.write_text(
        make_yosys_script_timing(
            liberty, rtl_path, netlist_path, stat_path, check_path,
            timing_path, abc_script_path,
        ),
        encoding="utf-8",
    )

    with log_path.open("w", encoding="utf-8") as log_file:
        result = subprocess.run(
            [yosys_bin, "-s", str(ys_script_path)],
            cwd=repo_root,
            stdout=log_file,
            stderr=subprocess.STDOUT,
        )

    if result.returncode != 0:
        return _make_row(
            variant_name, in_data_width, out_data_width, target_mhz, period_ps,
            None, None, None, False, False, "FAIL", log_path,
        )

    stat_text = stat_path.read_text(encoding="utf-8") if stat_path.exists() else ""
    timing_text = timing_path.read_text(encoding="utf-8") if timing_path.exists() else ""
    check_text = check_path.read_text(encoding="utf-8") if check_path.exists() else ""

    delay_ps, area, cell_count, check_ok, timing_met, status = _parse_reports(
        stat_text, timing_text, check_text, period_ps
    )
    return _make_row(
        variant_name, in_data_width, out_data_width, target_mhz, period_ps,
        delay_ps, area, cell_count, check_ok, timing_met, status, log_path,
    )


def _make_row(variant_name, in_w, out_w, target_mhz, period_ps,
              delay_ps, area, cell_count, check_ok, timing_met, status, log_path):
    category, chunk_width, in_chunks, out_chunks = classify_case(in_w, out_w)
    fmax_estimate = round(1e6 / delay_ps) if delay_ps else None
    return {
        "variant": variant_name,
        "in_data_width": in_w,
        "out_data_width": out_w,
        "category": category,
        "chunk_width": chunk_width,
        "target_mhz": target_mhz,
        "period_ps": period_ps,
        "delay_ps": f"{delay_ps:.2f}" if delay_ps is not None else "",
        "fmax_estimate_mhz": fmax_estimate if fmax_estimate is not None else "",
        "timing_met": "yes" if timing_met else "no",
        "area": f"{area:.3f}" if area is not None else "",
        "cell_count": cell_count if cell_count is not None else "",
        "check_ok": "yes" if check_ok else "no",
        "status": status,
        "log": str(log_path),
    }


def write_csv(path, rows):
    fieldnames = (
        "variant", "in_data_width", "out_data_width", "category", "chunk_width",
        "target_mhz", "period_ps", "delay_ps", "fmax_estimate_mhz",
        "timing_met", "area", "cell_count", "check_ok", "status", "log",
    )
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def write_markdown(path, rows, in_w, out_w):
    lines = [
        f"# Timing Sweep: {in_w} → {out_w}",
        "",
        "| Target (MHz) | Period (ps) | Variant | Delay (ps) | Fmax Est. (MHz) | Met | Area (µm²) | Cells |",
        "|---:|---:|---|---:|---:|:---:|---:|---:|",
    ]
    for row in rows:
        met_marker = "✓" if row["timing_met"] == "yes" else "✗"
        lines.append(
            f"| {row['target_mhz']} | {row['period_ps']} | {row['variant']} "
            f"| {row['delay_ps']} | {row['fmax_estimate_mhz']} "
            f"| {met_marker} | {row['area']} | {row['cell_count']} |"
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def print_table(rows, in_w, out_w):
    print(f"\n=== Timing Sweep: {in_w} → {out_w} ===")
    hdr = f"{'MHz':>6}  {'Period(ps)':>10}  {'Variant':<22}  {'Delay(ps)':>10}  "
    hdr += f"{'Fmax Est':>10}  {'Met':>4}  {'Area(µm²)':>12}  {'Cells':>6}"
    print(hdr)
    print("-" * len(hdr))
    for row in rows:
        met = "YES" if row["timing_met"] == "yes" else " NO"
        print(
            f"{row['target_mhz']:>6}  {row['period_ps']:>10}  {row['variant']:<22}  "
            f"{row['delay_ps']:>10}  {str(row['fmax_estimate_mhz']):>10}  "
            f"{met:>4}  {row['area']:>12}  {str(row['cell_count']):>6}"
        )


def main():
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[1]

    if not args.liberty.exists():
        raise SystemExit(f"Liberty file not found: {args.liberty}")

    yosys_bin = shutil.which(args.yosys)
    if yosys_bin is None:
        raise SystemExit(f"Yosys not found: {args.yosys}")

    try:
        freqs = [int(f.strip()) for f in args.freqs.split(",")]
    except ValueError:
        raise SystemExit("--freqs must be comma-separated integers (MHz)")
    if not freqs:
        raise SystemExit("--freqs must have at least one value")

    active_variants = VARIANTS
    if args.variant == "adder":
        active_variants = (VARIANTS[0],)
    elif args.variant == "onehot":
        active_variants = (VARIANTS[1],)

    common_mux_text = read_common_mux(repo_root)
    variant_rtl = {
        name: read_variant_rtl(repo_root, source) for name, source in active_variants
    }

    build_root = args.build_dir.resolve()
    build_root.mkdir(parents=True, exist_ok=True)

    variant_names = ", ".join(name for name, _ in active_variants)
    n_tasks = len(freqs) * len(active_variants)
    print(f"pdk:        {args.pdk}  ({args.liberty.name})")
    print(f"conversion: {args.in_data_width}→{args.out_data_width}")
    print(f"freqs:      {', '.join(str(f) for f in freqs)} MHz  ({len(freqs)} points)")
    print(f"variants:   {variant_names}")
    print(f"jobs:       {args.jobs}  ({n_tasks} total syntheses)")
    print(f"build dir:  {build_root}")
    print()

    tasks = []
    for target_mhz in freqs:
        for variant_name, _ in active_variants:
            tasks.append((
                repo_root,
                yosys_bin,
                args.liberty,
                build_root,
                variant_name,
                variant_rtl[variant_name],
                common_mux_text,
                args.in_data_width,
                args.out_data_width,
                target_mhz,
                args.rerun,
            ))

    rows = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        future_to_task = {pool.submit(synthesize_one, t): t for t in tasks}
        for future in concurrent.futures.as_completed(future_to_task):
            row = future.result()
            rows.append(row)
            met = "MET" if row["timing_met"] == "yes" else "MISS"
            print(
                f"  {row['variant']:<22}  {row['target_mhz']:>4} MHz  "
                f"delay={row['delay_ps']:>10} ps  area={row['area']:>12}  {row['status']} {met}",
                flush=True,
            )

    rows.sort(key=lambda r: (r["target_mhz"], r["variant"]))

    csv_path = build_root / "timing_sweep.csv"
    md_path = build_root / "timing_sweep.md"
    write_csv(csv_path, rows)
    write_markdown(md_path, rows, args.in_data_width, args.out_data_width)
    print_table(rows, args.in_data_width, args.out_data_width)
    print(f"\nwrote {csv_path}")
    print(f"wrote {md_path}")

    failed = [r for r in rows if r["status"] != "PASS"]
    if failed:
        raise SystemExit(f"{len(failed)} synthesis run(s) failed")


if __name__ == "__main__":
    main()
