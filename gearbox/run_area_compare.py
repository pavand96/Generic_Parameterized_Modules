#!/usr/bin/env python3

import argparse
import concurrent.futures
import csv
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
  parse_area,
  parse_cell_count,
  parse_check_ok,
  pdk_liberty_path,
  prepare_rtl,
  read_common_mux,
  read_variant_rtl,
)


def parse_args():
  repo_root = Path(__file__).resolve().parents[1]
  parser = argparse.ArgumentParser(
    description="Compare gearbox mapped area for origin/main and current RTL."
  )
  parser.add_argument("--count", type=int, default=50)
  parser.add_argument("--seed", type=int, default=20260506)
  parser.add_argument("--max-data-width", type=int, default=1024)
  parser.add_argument("--max-chunks-per-beat", type=int, default=16)
  parser.add_argument(
    "--case-set",
    choices=("all", "non-integer"),
    default="all",
    help="Select which conversion categories to generate.",
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
  parser.add_argument("--build-dir", type=Path, default=Path("area_compare_build"))
  parser.add_argument("--yosys", default=os.environ.get("YOSYS", "yosys"))
  parser.add_argument("--jobs", type=int, default=os.cpu_count())
  parser.add_argument("--rerun", action="store_true")
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


def make_yosys_script(liberty, rtl_path, netlist_path, stat_path, check_path):
  return f"""
read_liberty -lib {liberty.resolve()}
read_verilog -sv -DSYNTHESIS {rtl_path.resolve()}
hierarchy -check -top gearbox
proc
opt
synth -top gearbox -flatten
dfflibmap -liberty {liberty.resolve()}
abc -liberty {liberty.resolve()}
clean
tee -o {stat_path.resolve()} stat -liberty {liberty.resolve()}
tee -o {check_path.resolve()} check
write_verilog -noattr {netlist_path.resolve()}
""".strip() + "\n"


def synthesize_one(task):
  (
    repo_root,
    yosys_bin,
    liberty,
    build_root,
    variant_name,
    rtl_text,
    common_mux_text,
    case_index,
    in_data_width,
    out_data_width,
    rerun,
  ) = task

  case_name = f"{case_index:02d}_{in_data_width}_to_{out_data_width}"
  case_dir = build_root / variant_name / case_name
  case_dir.mkdir(parents=True, exist_ok=True)

  rtl_path = case_dir / "gearbox_yosys.sv"
  script_path = case_dir / "gearbox_synth.ys"
  netlist_path = case_dir / "gearbox_mapped.v"
  stat_path = case_dir / "gearbox_stat.rpt"
  check_path = case_dir / "gearbox_check.rpt"
  log_path = case_dir / "yosys.log"

  if rerun or not stat_path.exists() or not check_path.exists():
    generated_rtl = prepare_rtl(
      variant_name,
      rtl_text,
      common_mux_text,
      in_data_width,
      out_data_width,
    )
    rtl_path.write_text(generated_rtl, encoding="utf-8")
    script_path.write_text(
      make_yosys_script(liberty, rtl_path, netlist_path, stat_path, check_path),
      encoding="utf-8",
    )
    with log_path.open("w", encoding="utf-8") as log_file:
      result = subprocess.run(
        [yosys_bin, "-s", str(script_path)],
        cwd=repo_root,
        stdout=log_file,
        stderr=subprocess.STDOUT,
      )
    if result.returncode != 0:
      return {
        "case": case_index,
        "variant": variant_name,
        "in_data_width": in_data_width,
        "out_data_width": out_data_width,
        "status": "FAIL",
        "area": "",
        "cell_count": "",
        "check_ok": "no",
        "log": str(log_path),
      }

  stat_text = stat_path.read_text(encoding="utf-8")
  check_text = check_path.read_text(encoding="utf-8")
  category, chunk_width, in_chunks, out_chunks = classify_case(
    in_data_width,
    out_data_width,
  )
  area = parse_area(stat_text)
  cell_count = parse_cell_count(stat_text)
  check_ok = parse_check_ok(check_text)

  return {
    "case": case_index,
    "variant": variant_name,
    "category": category,
    "in_data_width": in_data_width,
    "out_data_width": out_data_width,
    "chunk_width": chunk_width,
    "in_chunks": in_chunks,
    "out_chunks": out_chunks,
    "status": "PASS" if area is not None and check_ok else "FAIL",
    "area": area if area is not None else "",
    "cell_count": cell_count if cell_count is not None else "",
    "check_ok": "yes" if check_ok else "no",
    "log": str(log_path),
  }


def write_csv(path, rows):
  fieldnames = (
    "case",
    "variant",
    "category",
    "in_data_width",
    "out_data_width",
    "chunk_width",
    "in_chunks",
    "out_chunks",
    "status",
    "area",
    "cell_count",
    "check_ok",
    "log",
  )
  with path.open("w", encoding="utf-8", newline="") as csv_file:
    writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(rows)


def write_markdown(path, rows):
  by_case = {}
  for row in rows:
    by_case.setdefault(row["case"], {})[row["variant"]] = row

  lines = []
  lines.append("| Case | Conversion | Category | Chunk Width | Origin/Main Adder Area | Current One-Hot Area | Delta | Delta % |")
  lines.append("|---:|---:|---|---:|---:|---:|---:|---:|")

  for case_index in sorted(by_case):
    adder = by_case[case_index].get(VARIANT_ADDER)
    onehot = by_case[case_index].get(VARIANT_ONEHOT)
    ref = onehot or adder

    if not adder or not onehot or adder["status"] != "PASS" or onehot["status"] != "PASS":
      lines.append(
        f"| {case_index} | {ref['in_data_width']} -> {ref['out_data_width']} | {ref.get('category', '')} | {ref.get('chunk_width', '')} | FAIL | FAIL |  |  |"
      )
      continue

    adder_area = float(adder["area"])
    onehot_area = float(onehot["area"])
    delta = onehot_area - adder_area
    delta_pct = 100.0 * delta / adder_area if adder_area else 0.0
    lines.append(
      f"| {case_index} | {ref['in_data_width']} -> {ref['out_data_width']} | {ref['category']} | {ref['chunk_width']} | {adder_area:.3f} | {onehot_area:.3f} | {delta:.3f} | {delta_pct:.2f}% |"
    )

  path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
  args = parse_args()
  repo_root = Path(__file__).resolve().parents[1]

  if not args.liberty.exists():
    raise SystemExit(f"Liberty file not found: {args.liberty}")

  yosys_bin = shutil.which(args.yosys)
  if yosys_bin is None:
    raise SystemExit(f"Yosys not found: {args.yosys}")

  common_mux_text = read_common_mux(repo_root)
  variant_rtl = {
    variant_name: read_variant_rtl(repo_root, variant_source)
    for variant_name, variant_source in VARIANTS
  }

  cases = generate_cases(
    args.count,
    args.seed,
    args.max_data_width,
    args.max_chunks_per_beat,
    args.case_set,
  )
  if args.limit is not None:
    cases = cases[:args.limit]

  build_root = args.build_dir.resolve()
  build_root.mkdir(parents=True, exist_ok=True)

  variant_names = ", ".join(name for name, _ in VARIANTS)
  n_tasks = len(cases) * len(VARIANTS)
  print(f"pdk:       {args.pdk}  ({args.liberty.name})")
  print(f"cases:     {len(cases)}  (set={args.case_set}, seed={args.seed}, count={args.count}"
        + (f", limit={args.limit}" if args.limit is not None else "") + ")")
  print(f"variants:  {variant_names}")
  print(f"jobs:      {args.jobs}  ({n_tasks} total syntheses)")
  print(f"build dir: {build_root}")
  print()

  tasks = []
  for case_index, (in_data_width, out_data_width) in enumerate(cases, start=1):
    for variant_name, _ in VARIANTS:
      tasks.append(
        (
          repo_root,
          yosys_bin,
          args.liberty,
          build_root,
          variant_name,
          variant_rtl[variant_name],
          common_mux_text,
          case_index,
          in_data_width,
          out_data_width,
          args.rerun,
        )
      )

  rows = []
  with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
    future_to_task = {
      executor.submit(synthesize_one, task): task
      for task in tasks
    }
    for future in concurrent.futures.as_completed(future_to_task):
      row = future.result()
      rows.append(row)
      print(
        f"{row['variant']} case {row['case']:02d} "
        f"{row['in_data_width']}->{row['out_data_width']} "
        f"{row['status']} area={row['area']}",
        flush=True,
      )

  rows.sort(key=lambda row: (row["case"], row["variant"]))
  csv_path = build_root / "area_compare.csv"
  md_path = build_root / "area_compare.md"
  write_csv(csv_path, rows)
  write_markdown(md_path, rows)

  failed = [row for row in rows if row["status"] != "PASS"]
  print(f"wrote {csv_path}")
  print(f"wrote {md_path}")
  if failed:
    raise SystemExit(f"{len(failed)} synthesis runs failed")


if __name__ == "__main__":
  main()
