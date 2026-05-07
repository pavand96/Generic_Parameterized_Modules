#!/usr/bin/env python3
"""Binary-search maximum clock frequency (Fmax) for gearbox implementations.

For each generated width pair and each implementation variant (adder/one-hot),
binary-searches the minimum achievable clock period using Yosys+ABC.  Reports
Fmax and area-at-Fmax so you can compare how hard each implementation can be
pushed.

How timing works
----------------
Each synthesis run uses 'abc -liberty <lib> -script <abc_script>' where the
abc script hardcodes the candidate period (ps) and ends with ABC's 'stime'
command.  The critical-path delay is parsed from:
    WireLoad = "none"  Gates = ...  Delay = <value> ps  ...
If delay ≤ period: timing is met.  Binary search narrows to the tightest
meeting period → Fmax = 1e6 / period_ps  (MHz).

Binary search bounds
--------------------
  --fmax-lo-mhz  (default 50)   : lowest frequency to try.  Should be
                                   trivially met by any design.
  --fmax-hi-mhz  (default 3000) : highest frequency to attempt.  Designs
                                   that can beat this appear as ">= <hi>".
  --fmax-precision-ps (default 50): binary search stops when the period
                                   window is narrower than this value.
  Iterations ≈ log2((lo_period − hi_period) / precision) ≈ 9–11 per case.

Example – SKY130, 20 random non-integer cases:
    python3 run_fmax_compare.py --count 20 --case-set non-integer --jobs 4

Example – ASAP7, 20 cases, up to 5 GHz:
    python3 run_fmax_compare.py --count 20 --case-set non-integer --jobs 4 \\
        --liberty ../../third_party/asap7/asap7sc7p5t_RVT_TT_nldm_merged.lib \\
        --fmax-hi-mhz 5000 \\
        --build-dir fmax_compare_asap7
"""

import argparse
import concurrent.futures
import csv
import math
import os
import shutil
import subprocess
from pathlib import Path

from gearbox_synth_lib import (
    PDK_CHOICES,
    VARIANT_ADDER,
    VARIANT_ONEHOT,
    VARIANTS,
    classify_case,
    generate_cases,
    make_abc_script,
    make_yosys_script_timing,
    parse_area,
    parse_cell_count,
    parse_delay_ps,
    pdk_liberty_path,
    prepare_rtl,
    read_common_mux,
    read_variant_rtl,
)


def parse_args():
    repo_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(
        description="Binary-search Fmax for gearbox adder vs one-hot implementations.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--count", type=int, default=20)
    parser.add_argument("--seed", type=int, default=20260506)
    parser.add_argument("--max-data-width", type=int, default=1024)
    parser.add_argument("--max-chunks-per-beat", type=int, default=16)
    parser.add_argument(
        "--case-set",
        choices=("all", "non-integer"),
        default="non-integer",
        help="Which conversion categories to include.",
    )
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
    parser.add_argument("--build-dir", type=Path, default=Path("fmax_compare_build"))
    parser.add_argument("--yosys", default=os.environ.get("YOSYS", "yosys"))
    parser.add_argument("--jobs", type=int, default=os.cpu_count())
    parser.add_argument("--rerun", action="store_true")
    parser.add_argument(
        "--fmax-lo-mhz",
        type=int,
        default=50,
        help="Lowest frequency tested.  Should trivially meet timing for all cases.",
    )
    parser.add_argument(
        "--fmax-hi-mhz",
        type=int,
        default=3000,
        help="Highest frequency attempted.  Fmax above this appears as '>= <hi>'.",
    )
    parser.add_argument(
        "--fmax-precision-ps",
        type=int,
        default=50,
        help="Binary search stops when the period window is narrower than this (ps).",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        metavar="N",
        help="Run only the first N cases from the generated set (default: all).",
    )
    args = parser.parse_args()
    if args.liberty is None:
        args.liberty = pdk_liberty_path(args.pdk, repo_root)
    return args


def synthesize_at_period(repo_root, yosys_bin, liberty, case_dir, rtl_path, period_ps, rerun=False):
    run_dir = case_dir / f"period_{period_ps:06d}ps"
    run_dir.mkdir(parents=True, exist_ok=True)

    abc_script_path = run_dir / "abc_timing.script"
    ys_script_path = run_dir / "gearbox_synth.ys"
    netlist_path = run_dir / "gearbox_mapped.v"
    stat_path = run_dir / "gearbox_stat.rpt"
    check_path = run_dir / "gearbox_check.rpt"
    timing_path = run_dir / "gearbox_timing.rpt"
    log_path = run_dir / "yosys.log"

    if not rerun and timing_path.exists() and stat_path.exists():
        stat_text = stat_path.read_text(encoding="utf-8")
        timing_text = timing_path.read_text(encoding="utf-8")
        delay = parse_delay_ps(timing_text)
        if delay is not None:
            return delay, parse_area(stat_text), parse_cell_count(stat_text)

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
        return None, None, None

    stat_text = stat_path.read_text(encoding="utf-8") if stat_path.exists() else ""
    timing_text = timing_path.read_text(encoding="utf-8") if timing_path.exists() else ""

    return (
        parse_delay_ps(timing_text),
        parse_area(stat_text),
        parse_cell_count(stat_text),
    )


def find_fmax_for_case(
    repo_root, yosys_bin, liberty, build_root,
    variant_name, rtl_text, common_mux_text,
    case_index, in_data_width, out_data_width,
    fmax_lo_mhz, fmax_hi_mhz, fmax_precision_ps,
    rerun,
):
    case_name = f"{case_index:02d}_{in_data_width}_to_{out_data_width}"
    case_dir = build_root / variant_name / case_name
    case_dir.mkdir(parents=True, exist_ok=True)

    summary_path = case_dir / "fmax_result.txt"
    if not rerun and summary_path.exists():
        cached = {}
        for line in summary_path.read_text().splitlines():
            k, _, v = line.partition("=")
            cached[k.strip()] = v.strip()
        result = _parse_cached_result(cached, case_index, in_data_width, out_data_width, variant_name)
        result["_from_cache"] = True
        return result

    rtl_path = case_dir / "gearbox_yosys.sv"
    rtl_path.write_text(
        prepare_rtl(variant_name, rtl_text, common_mux_text, in_data_width, out_data_width),
        encoding="utf-8",
    )

    lo_ps = int(round(1e6 / fmax_hi_mhz))
    hi_ps = int(round(1e6 / fmax_lo_mhz))

    category, chunk_width, in_chunks, out_chunks = classify_case(in_data_width, out_data_width)

    def _synth(period_ps):
        return synthesize_at_period(
            repo_root, yosys_bin, liberty, case_dir, rtl_path, period_ps, rerun,
        )

    delay, area, cells = _synth(hi_ps)
    if delay is None:
        return _fail_result(case_index, in_data_width, out_data_width, variant_name,
                            category, chunk_width, in_chunks, out_chunks,
                            "synthesis error at loose period")

    if delay > hi_ps:
        return _fail_result(case_index, in_data_width, out_data_width, variant_name,
                            category, chunk_width, in_chunks, out_chunks,
                            f"delay {delay:.0f}ps > loose period {hi_ps}ps")

    best_ps = hi_ps
    best_area = area
    best_cells = cells
    best_delay = delay

    delay_lo, area_lo, cells_lo = _synth(lo_ps)
    if delay_lo is not None and delay_lo <= lo_ps:
        result = _make_result(
            case_index, in_data_width, out_data_width, variant_name,
            category, chunk_width, in_chunks, out_chunks,
            fmax_hi_mhz, lo_ps, area_lo, cells_lo, delay_lo,
            capped_high=True,
        )
        _write_summary(summary_path, result)
        return result

    lo_current = lo_ps
    hi_current = hi_ps

    while hi_current - lo_current > fmax_precision_ps:
        mid_ps = (lo_current + hi_current) // 2
        delay, area, cells = _synth(mid_ps)
        if delay is not None and delay <= mid_ps:
            hi_current = mid_ps
            best_ps = mid_ps
            best_area = area
            best_cells = cells
            best_delay = delay
        else:
            lo_current = mid_ps

    fmax_mhz = round(1e6 / best_ps, 1)
    result = _make_result(
        case_index, in_data_width, out_data_width, variant_name,
        category, chunk_width, in_chunks, out_chunks,
        fmax_mhz, best_ps, best_area, best_cells, best_delay,
        capped_high=False,
    )
    _write_summary(summary_path, result)
    return result


def _make_result(case_index, in_w, out_w, variant_name,
                 category, chunk_width, in_chunks, out_chunks,
                 fmax_mhz, fmax_period_ps, area, cells, delay_ps,
                 capped_high=False):
    return {
        "case": case_index,
        "variant": variant_name,
        "in_data_width": in_w,
        "out_data_width": out_w,
        "category": category,
        "chunk_width": chunk_width,
        "in_chunks": in_chunks,
        "out_chunks": out_chunks,
        "status": "PASS",
        "fmax_mhz": f"{fmax_mhz:.1f}",
        "fmax_period_ps": fmax_period_ps,
        "area": f"{area:.3f}" if area is not None else "",
        "cell_count": cells if cells is not None else "",
        "delay_at_fmax_ps": f"{delay_ps:.2f}" if delay_ps is not None else "",
        "capped_high": "yes" if capped_high else "no",
    }


def _fail_result(case_index, in_w, out_w, variant_name,
                 category, chunk_width, in_chunks, out_chunks, reason):
    return {
        "case": case_index,
        "variant": variant_name,
        "in_data_width": in_w,
        "out_data_width": out_w,
        "category": category,
        "chunk_width": chunk_width,
        "in_chunks": in_chunks,
        "out_chunks": out_chunks,
        "status": "FAIL",
        "fmax_mhz": "",
        "fmax_period_ps": "",
        "area": "",
        "cell_count": "",
        "delay_at_fmax_ps": "",
        "capped_high": "no",
        "fail_reason": reason,
    }


def _parse_cached_result(cached, case_index, in_w, out_w, variant_name):
    category, chunk_width, in_chunks, out_chunks = classify_case(in_w, out_w)
    return {
        "case": case_index,
        "variant": variant_name,
        "in_data_width": in_w,
        "out_data_width": out_w,
        "category": category,
        "chunk_width": chunk_width,
        "in_chunks": in_chunks,
        "out_chunks": out_chunks,
        "status": cached.get("status", "FAIL"),
        "fmax_mhz": cached.get("fmax_mhz", ""),
        "fmax_period_ps": cached.get("fmax_period_ps", ""),
        "area": cached.get("area", ""),
        "cell_count": cached.get("cell_count", ""),
        "delay_at_fmax_ps": cached.get("delay_at_fmax_ps", ""),
        "capped_high": cached.get("capped_high", "no"),
    }


def _write_summary(path, result):
    lines = [f"{k} = {v}" for k, v in result.items()]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


CSV_FIELDS = (
    "case", "variant", "in_data_width", "out_data_width",
    "category", "chunk_width", "in_chunks", "out_chunks",
    "status", "fmax_mhz", "fmax_period_ps",
    "area", "cell_count", "delay_at_fmax_ps", "capped_high",
)


def write_csv(path, rows):
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def write_markdown(path, rows, fmax_hi_mhz):
    by_case = {}
    for row in rows:
        by_case.setdefault(row["case"], {})[row["variant"]] = row

    lines = [
        "| Case | Conversion | Category | Chunk W | "
        "Adder Fmax (MHz) | Onehot Fmax (MHz) | Fmax Ratio (onehot/adder) | "
        "Adder Area (µm²) | Onehot Area (µm²) | Area Ratio |",
        "|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|",
    ]

    for case_index in sorted(by_case):
        adder = by_case[case_index].get(VARIANT_ADDER)
        onehot = by_case[case_index].get(VARIANT_ONEHOT)
        ref = onehot or adder
        in_w = ref["in_data_width"]
        out_w = ref["out_data_width"]
        cat = ref.get("category", "")
        cw = ref.get("chunk_width", "")

        if not adder or not onehot or adder["status"] != "PASS" or onehot["status"] != "PASS":
            lines.append(
                f"| {case_index} | {in_w}→{out_w} | {cat} | {cw} "
                f"| FAIL | FAIL | – | – | – | – |"
            )
            continue

        adder_fmax = float(adder["fmax_mhz"]) if adder["fmax_mhz"] else None
        onehot_fmax = float(onehot["fmax_mhz"]) if onehot["fmax_mhz"] else None
        adder_area = float(adder["area"]) if adder["area"] else None
        onehot_area = float(onehot["area"]) if onehot["area"] else None

        adder_cap = adder.get("capped_high") == "yes"
        onehot_cap = onehot.get("capped_high") == "yes"

        fmax_ratio_str = "–"
        if adder_fmax and onehot_fmax and adder_fmax > 0:
            fmax_ratio_str = f"{onehot_fmax / adder_fmax:.3f}"

        area_ratio_str = "–"
        if adder_area and onehot_area and adder_area > 0:
            area_ratio_str = f"{onehot_area / adder_area:.3f}"

        adder_fmax_str = f"{adder_fmax:.0f}" + (f" (≥{fmax_hi_mhz})" if adder_cap else "")
        onehot_fmax_str = f"{onehot_fmax:.0f}" + (f" (≥{fmax_hi_mhz})" if onehot_cap else "")

        lines.append(
            f"| {case_index} | {in_w}→{out_w} | {cat} | {cw} "
            f"| {adder_fmax_str} | {onehot_fmax_str} | {fmax_ratio_str} "
            f"| {adder_area:.1f} | {onehot_area:.1f} | {area_ratio_str} |"
        )

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_summary_stats(rows, fmax_hi_mhz):
    by_case = {}
    for row in rows:
        by_case.setdefault(row["case"], {})[row["variant"]] = row

    fmax_ratios = []
    area_ratios = []
    cat_fmax = {}
    cat_area = {}

    for adder, onehot in (
        (by_case[c].get(VARIANT_ADDER), by_case[c].get(VARIANT_ONEHOT))
        for c in sorted(by_case)
    ):
        if not adder or not onehot:
            continue
        if adder["status"] != "PASS" or onehot["status"] != "PASS":
            continue
        af = float(adder["fmax_mhz"]) if adder["fmax_mhz"] else None
        of = float(onehot["fmax_mhz"]) if onehot["fmax_mhz"] else None
        aa = float(adder["area"]) if adder["area"] else None
        oa = float(onehot["area"]) if onehot["area"] else None
        cat = adder.get("category", "unknown")
        if af and of:
            ratio = of / af
            fmax_ratios.append(ratio)
            cat_fmax.setdefault(cat, []).append(ratio)
        if aa and oa:
            ratio = oa / aa
            area_ratios.append(ratio)
            cat_area.setdefault(cat, []).append(ratio)

    def geomean(vals):
        if not vals:
            return float("nan")
        return math.exp(sum(math.log(v) for v in vals) / len(vals))

    print(f"\n{'='*60}")
    print("Summary statistics (onehot / adder)")
    print(f"{'='*60}")
    if fmax_ratios:
        print(f"  Fmax geomean ratio  (all): {geomean(fmax_ratios):.4f}")
    if area_ratios:
        print(f"  Area geomean ratio  (all): {geomean(area_ratios):.4f}")
    for cat in sorted(set(list(cat_fmax) + list(cat_area))):
        frats = cat_fmax.get(cat, [])
        arats = cat_area.get(cat, [])
        fstr = f"{geomean(frats):.4f}" if frats else "–"
        astr = f"{geomean(arats):.4f}" if arats else "–"
        print(f"  {cat:<28} fmax_ratio={fstr}  area_ratio={astr}")
    print()


def main():
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[1]

    if not args.liberty.exists():
        raise SystemExit(f"Liberty file not found: {args.liberty}")

    yosys_bin = shutil.which(args.yosys)
    if yosys_bin is None:
        raise SystemExit(f"Yosys not found: {args.yosys}")

    if args.fmax_lo_mhz >= args.fmax_hi_mhz:
        raise SystemExit("--fmax-lo-mhz must be less than --fmax-hi-mhz")

    common_mux_text = read_common_mux(repo_root)
    variant_rtl = {
        name: read_variant_rtl(repo_root, source) for name, source in VARIANTS
    }

    cases = generate_cases(
        args.count, args.seed, args.max_data_width,
        args.max_chunks_per_beat, args.case_set,
    )
    if args.limit is not None:
        cases = cases[:args.limit]

    build_root = args.build_dir.resolve()
    build_root.mkdir(parents=True, exist_ok=True)

    variant_names = ", ".join(name for name, _ in VARIANTS)
    n_tasks = len(cases) * len(VARIANTS)
    print(f"pdk:        {args.pdk}  ({args.liberty.name})")
    print(f"cases:      {len(cases)}  (set={args.case_set}, seed={args.seed}, count={args.count}"
          + (f", limit={args.limit}" if args.limit is not None else "") + ")")
    print(f"variants:   {variant_names}")
    print(f"jobs:       {args.jobs}  ({n_tasks} total searches)")
    print(f"build dir:  {build_root}")
    print(f"fmax range: {args.fmax_lo_mhz}–{args.fmax_hi_mhz} MHz  (precision {args.fmax_precision_ps} ps)")
    print()

    tasks = []
    for case_index, (in_w, out_w) in enumerate(cases, start=1):
        for variant_name, _ in VARIANTS:
            tasks.append((
                repo_root,
                yosys_bin,
                args.liberty,
                build_root,
                variant_name,
                variant_rtl[variant_name],
                common_mux_text,
                case_index,
                in_w,
                out_w,
                args.fmax_lo_mhz,
                args.fmax_hi_mhz,
                args.fmax_precision_ps,
                args.rerun,
            ))

    rows = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        future_to_task = {
            pool.submit(find_fmax_for_case, *t): t for t in tasks
        }
        for future in concurrent.futures.as_completed(future_to_task):
            row = future.result()
            rows.append(row)
            cap = " (capped)" if row.get("capped_high") == "yes" else ""
            src = " (cached)" if row.get("_from_cache") else ""
            print(
                f"  case {row['case']:02d} {row['in_data_width']:>4}→{row['out_data_width']:<4} "
                f"{row['variant']:<22} {row['status']}  "
                f"fmax={row['fmax_mhz']:>8} MHz{cap}  area={row['area']:>12}{src}",
                flush=True,
            )

    rows.sort(key=lambda r: (r["case"], r["variant"]))

    csv_path = build_root / "fmax_compare.csv"
    md_path = build_root / "fmax_compare.md"
    write_csv(csv_path, rows)
    write_markdown(md_path, rows, args.fmax_hi_mhz)
    write_summary_stats(rows, args.fmax_hi_mhz)

    print(f"wrote {csv_path}")
    print(f"wrote {md_path}")

    failed = [r for r in rows if r["status"] != "PASS"]
    if failed:
        raise SystemExit(f"{len(failed)} case(s) failed")


if __name__ == "__main__":
    main()
