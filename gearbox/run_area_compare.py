#!/usr/bin/env python3

import argparse
import concurrent.futures
import csv
import math
import os
import random
import re
import shutil
import subprocess
from pathlib import Path


VARIANTS = (
  ("adder_origin_main", "origin/main:gearbox/gearbox.sv"),
  ("onehot_current", None),
)


def parse_args():
  repo_root = Path(__file__).resolve().parents[1]
  default_liberty = (
    repo_root
    / "third_party"
    / "sky130_fd_sc_hd"
    / "timing"
    / "sky130_fd_sc_hd__tt_025C_1v80.lib"
  )

  parser = argparse.ArgumentParser(
    description="Compare gearbox SKY130 mapped area for origin/main and current RTL."
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
  parser.add_argument("--liberty", type=Path, default=default_liberty)
  parser.add_argument("--build-dir", type=Path, default=Path("area_compare_build"))
  parser.add_argument("--yosys", default=os.environ.get("YOSYS", "yosys"))
  parser.add_argument("--jobs", type=int, default=1)
  parser.add_argument("--rerun", action="store_true")
  return parser.parse_args()


def run_command(cmd, cwd):
  return subprocess.check_output(cmd, cwd=cwd, text=True)


def read_variant_rtl(repo_root, variant_source):
  if variant_source is None:
    return (repo_root / "gearbox" / "gearbox.sv").read_text(encoding="utf-8")
  return run_command(["git", "show", variant_source], repo_root)


def read_common_mux(repo_root):
  common_text = (repo_root / "common" / "common_pkg.sv").read_text(encoding="utf-8")
  module_start = common_text.index("module common_chunk_mux")
  return common_text[module_start:]


def replace_common_parameters(rtl_text, in_data_width, out_data_width):
  chunk_width = math.gcd(in_data_width, out_data_width)
  rtl_text = rtl_text.replace("import common_pkg::*;\n\n", "")
  rtl_text = re.sub(
    r"parameter int unsigned IN_DATA_WIDTH\s*=\s*\d+",
    f"parameter int unsigned IN_DATA_WIDTH      = {in_data_width}",
    rtl_text,
  )
  rtl_text = re.sub(
    r"parameter int unsigned OUT_DATA_WIDTH\s*=\s*\d+",
    f"parameter int unsigned OUT_DATA_WIDTH     = {out_data_width}",
    rtl_text,
  )
  rtl_text = re.sub(
    r"(localparam int unsigned CHUNK_WIDTH\s*=\s*)greatest_common_divisor\(IN_DATA_WIDTH, OUT_DATA_WIDTH\)([,;])",
    rf"\g<1>{chunk_width}\2",
    rtl_text,
  )
  return rtl_text


def flatten_current_onehot_arrays(rtl_text):
  replacements = (
    (
      "logic [BUFFER_CAPACITY_CHUNKS-1:0][CHUNK_WIDTH-1:0] pack_buffer_q;",
      "logic [BUFFER_DATA_WIDTH-1:0] pack_buffer_q;",
    ),
    (
      "logic [BUFFER_CAPACITY_CHUNKS-1:0][CHUNK_WIDTH-1:0] chunk_wr_data;",
      "logic [BUFFER_DATA_WIDTH-1:0] chunk_wr_data;",
    ),
    (
      "logic [IN_CHUNKS_PER_BEAT-1:0][BUFFER_CAPACITY_CHUNKS-1:0] in_chunk_wr_dst_oh;",
      "logic [IN_CHUNKS_PER_BEAT*BUFFER_CAPACITY_CHUNKS-1:0] in_chunk_wr_dst_oh;",
    ),
    (
      "logic [OUT_CHUNKS_PER_BEAT-1:0][BUFFER_CAPACITY_CHUNKS-1:0] out_chunk_rd_src_oh;",
      "logic [OUT_CHUNKS_PER_BEAT*BUFFER_CAPACITY_CHUNKS-1:0] out_chunk_rd_src_oh;",
    ),
    (
      "pack_buffer_q[out_chunk_i]",
      "pack_buffer_q[CHUNK_WIDTH*out_chunk_i +: CHUNK_WIDTH]",
    ),
    (
      "chunk_wr_data[out_chunk_i][chunk_bit_i]",
      "chunk_wr_data[CHUNK_WIDTH*out_chunk_i+chunk_bit_i]",
    ),
    (
      "chunk_wr_data[out_chunk_i]",
      "chunk_wr_data[CHUNK_WIDTH*out_chunk_i +: CHUNK_WIDTH]",
    ),
    (
      "in_chunk_wr_dst_oh[in_chunk_i][out_chunk_i]",
      "in_chunk_wr_dst_oh[BUFFER_CAPACITY_CHUNKS*in_chunk_i+out_chunk_i]",
    ),
    (
      "assign in_chunk_wr_dst_oh[in_chunk_i] =",
      "assign in_chunk_wr_dst_oh[BUFFER_CAPACITY_CHUNKS*in_chunk_i +: BUFFER_CAPACITY_CHUNKS] =",
    ),
    (
      "out_chunk_rd_src_oh[out_chunk_i][buffer_chunk_i]",
      "out_chunk_rd_src_oh[BUFFER_CAPACITY_CHUNKS*out_chunk_i+buffer_chunk_i]",
    ),
    (
      "assign out_chunk_rd_src_oh[out_chunk_i] =",
      "assign out_chunk_rd_src_oh[BUFFER_CAPACITY_CHUNKS*out_chunk_i +: BUFFER_CAPACITY_CHUNKS] =",
    ),
  )

  for old, new in replacements:
    rtl_text = rtl_text.replace(old, new)

  return rtl_text


def flatten_origin_adder_arrays(rtl_text):
  replacements = (
    (
      "logic [IN_CHUNKS_PER_BEAT-1:0][BUFFER_PTR_WIDTH-1:0] write_dst_chunk_ptr;",
      "logic [IN_CHUNKS_PER_BEAT*BUFFER_PTR_WIDTH-1:0] write_dst_chunk_ptr;",
    ),
    (
      "logic [OUT_CHUNKS_PER_BEAT-1:0][BUFFER_PTR_WIDTH-1:0] read_src_chunk_ptr;",
      "logic [OUT_CHUNKS_PER_BEAT*BUFFER_PTR_WIDTH-1:0] read_src_chunk_ptr;",
    ),
    (
      "write_dst_chunk_ptr[in_chunk_i]",
      "write_dst_chunk_ptr[BUFFER_PTR_WIDTH*in_chunk_i +: BUFFER_PTR_WIDTH]",
    ),
    (
      "read_src_chunk_ptr[out_chunk_i]",
      "read_src_chunk_ptr[BUFFER_PTR_WIDTH*out_chunk_i +: BUFFER_PTR_WIDTH]",
    ),
  )

  for old, new in replacements:
    rtl_text = rtl_text.replace(old, new)

  return rtl_text


def prepare_rtl(variant_name, rtl_text, common_mux_text, in_data_width, out_data_width):
  rtl_text = replace_common_parameters(rtl_text, in_data_width, out_data_width)

  if variant_name == "onehot_current":
    rtl_text = flatten_current_onehot_arrays(rtl_text)
  else:
    rtl_text = flatten_origin_adder_arrays(rtl_text)
    rtl_text = common_mux_text + "\n\n" + rtl_text

  return rtl_text


def classify_case(in_data_width, out_data_width):
  chunk_width = math.gcd(in_data_width, out_data_width)
  in_chunks = in_data_width // chunk_width
  out_chunks = out_data_width // chunk_width

  if in_chunks == out_chunks:
    return "equal", chunk_width, in_chunks, out_chunks

  max_chunks = max(in_chunks, out_chunks)
  min_chunks = min(in_chunks, out_chunks)
  exact = (max_chunks % min_chunks) == 0
  direction = "pack" if in_chunks < out_chunks else "unpack"
  ratio = "integer" if exact else "non_integer"
  return f"{ratio}_{direction}", chunk_width, in_chunks, out_chunks


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


def parse_area(stat_text):
  match = re.search(r"Chip area for module '\\gearbox':\s+([0-9.]+)", stat_text)
  if not match:
    return None
  return float(match.group(1))


def parse_cell_count(stat_text):
  match = re.search(r"\n\s+(\d+)\s+[0-9.Ee+-]+\s+cells\n", stat_text)
  if not match:
    return None
  return int(match.group(1))


def parse_check_ok(check_text):
  return "Found and reported 0 problems." in check_text


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


def add_unique_case(cases, seen, in_units, out_units, max_units, max_chunks_per_beat):
  if in_units < 1 or out_units < 1:
    return False
  if in_units > max_units or out_units > max_units:
    return False
  pair = (8 * in_units, 8 * out_units)
  if pair in seen:
    return False
  _, _, in_chunks, out_chunks = classify_case(pair[0], pair[1])
  if max(in_chunks, out_chunks) > max_chunks_per_beat:
    return False
  seen.add(pair)
  cases.append(pair)
  return True


def generate_cases(count, seed, max_data_width, max_chunks_per_beat, case_set):
  if max_data_width % 8 != 0:
    raise SystemExit("--max-data-width must be byte aligned")

  rng = random.Random(seed)
  max_units = max_data_width // 8
  cases = []
  seen = set()
  if case_set == "non-integer":
    categories = (
      "non_integer_pack",
      "non_integer_unpack",
    )
  else:
    categories = (
      "equal",
      "integer_pack",
      "integer_unpack",
      "non_integer_pack",
      "non_integer_unpack",
    )

  attempts = 0
  while len(cases) < count and attempts < count * 1000:
    attempts += 1
    category = categories[len(cases) % len(categories)]

    if category == "equal":
      units = rng.randint(1, max_units)
      add_unique_case(cases, seen, units, units, max_units, max_chunks_per_beat)

    elif category == "integer_pack":
      ratio = rng.choice((2, 3, 4, 5, 6, 8, 16))
      in_units = rng.randint(1, max(1, max_units // ratio))
      add_unique_case(cases, seen, in_units, in_units * ratio, max_units, max_chunks_per_beat)

    elif category == "integer_unpack":
      ratio = rng.choice((2, 3, 4, 5, 6, 8, 16))
      out_units = rng.randint(1, max(1, max_units // ratio))
      add_unique_case(cases, seen, out_units * ratio, out_units, max_units, max_chunks_per_beat)

    elif category == "non_integer_pack":
      in_units = rng.randint(1, max_units - 1)
      out_units = rng.randint(in_units + 1, max_units)
      if out_units % in_units != 0:
        add_unique_case(cases, seen, in_units, out_units, max_units, max_chunks_per_beat)

    else:
      out_units = rng.randint(1, max_units - 1)
      in_units = rng.randint(out_units + 1, max_units)
      if in_units % out_units != 0:
        add_unique_case(cases, seen, in_units, out_units, max_units, max_chunks_per_beat)

  if len(cases) != count:
    raise SystemExit(f"Could only generate {len(cases)} unique cases")

  return cases


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
    adder = by_case[case_index].get("adder_origin_main")
    onehot = by_case[case_index].get("onehot_current")
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
  build_root = args.build_dir.resolve()
  build_root.mkdir(parents=True, exist_ok=True)

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
