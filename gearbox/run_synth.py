#!/usr/bin/env python3

import argparse
import math
import os
import re
import shutil
import subprocess
from pathlib import Path


def parse_args():
  repo_root = Path(__file__).resolve().parents[1]
  default_lib = (
    repo_root
    / "third_party"
    / "sky130_fd_sc_hd"
    / "timing"
    / "sky130_fd_sc_hd__tt_025C_1v80.lib"
  )

  parser = argparse.ArgumentParser(
    description="Run standalone Yosys synthesis for gearbox using SKY130 HD liberty."
  )
  parser.add_argument("--in-data-width", type=int, default=24)
  parser.add_argument("--out-data-width", type=int, default=40)
  parser.add_argument("--liberty", type=Path, default=default_lib)
  parser.add_argument("--build-dir", type=Path, default=Path("synth_build"))
  parser.add_argument("--yosys", default=os.environ.get("YOSYS", "yosys"))
  parser.add_argument("--no-flatten", action="store_true")
  return parser.parse_args()


def main():
  args = parse_args()
  repo_root = Path(__file__).resolve().parents[1]
  gearbox_dir = Path(__file__).resolve().parent
  build_dir = args.build_dir

  if not args.liberty.exists():
    raise SystemExit(f"Liberty file not found: {args.liberty}")

  yosys_bin = shutil.which(args.yosys)
  if yosys_bin is None:
    raise SystemExit(f"Yosys not found: {args.yosys}")

  build_dir.mkdir(parents=True, exist_ok=True)

  synth_script = build_dir / "gearbox_synth.ys"
  synth_rtl = build_dir / "gearbox_yosys.sv"
  netlist = build_dir / "gearbox_mapped.v"
  stat_report = build_dir / "gearbox_stat.rpt"
  check_report = build_dir / "gearbox_check.rpt"

  rtl_text = (gearbox_dir / "gearbox.sv").read_text(encoding="utf-8")
  chunk_width = math.gcd(args.in_data_width, args.out_data_width)
  rtl_text = rtl_text.replace("import common_pkg::*;\n\n", "")
  rtl_text = re.sub(
    r"parameter int unsigned IN_DATA_WIDTH\s*=\s*\d+",
    f"parameter int unsigned IN_DATA_WIDTH      = {args.in_data_width}",
    rtl_text,
  )
  rtl_text = re.sub(
    r"parameter int unsigned OUT_DATA_WIDTH\s*=\s*\d+",
    f"parameter int unsigned OUT_DATA_WIDTH     = {args.out_data_width}",
    rtl_text,
  )
  rtl_text = re.sub(
    r"localparam int unsigned CHUNK_WIDTH\s*=\s*greatest_common_divisor\(IN_DATA_WIDTH, OUT_DATA_WIDTH\);",
    f"localparam int unsigned CHUNK_WIDTH         = {chunk_width};",
    rtl_text,
  )
  rtl_text = rtl_text.replace(
    "logic [BUFFER_CAPACITY_CHUNKS-1:0][CHUNK_WIDTH-1:0] pack_buffer_q;",
    "logic [BUFFER_DATA_WIDTH-1:0] pack_buffer_q;",
  )
  rtl_text = rtl_text.replace(
    "logic [BUFFER_CAPACITY_CHUNKS-1:0][CHUNK_WIDTH-1:0] chunk_wr_data;",
    "logic [BUFFER_DATA_WIDTH-1:0] chunk_wr_data;",
  )
  rtl_text = rtl_text.replace(
    "logic [IN_CHUNKS_PER_BEAT-1:0][BUFFER_CAPACITY_CHUNKS-1:0] in_chunk_wr_dst_oh;",
    "logic [IN_CHUNKS_PER_BEAT*BUFFER_CAPACITY_CHUNKS-1:0] in_chunk_wr_dst_oh;",
  )
  rtl_text = rtl_text.replace(
    "logic [OUT_CHUNKS_PER_BEAT-1:0][BUFFER_CAPACITY_CHUNKS-1:0] out_chunk_rd_src_oh;",
    "logic [OUT_CHUNKS_PER_BEAT*BUFFER_CAPACITY_CHUNKS-1:0] out_chunk_rd_src_oh;",
  )
  rtl_text = rtl_text.replace(
    "pack_buffer_q[out_chunk_i]",
    "pack_buffer_q[CHUNK_WIDTH*out_chunk_i +: CHUNK_WIDTH]",
  )
  rtl_text = rtl_text.replace(
    "chunk_wr_data[out_chunk_i][chunk_bit_i]",
    "chunk_wr_data[CHUNK_WIDTH*out_chunk_i+chunk_bit_i]",
  )
  rtl_text = rtl_text.replace(
    "chunk_wr_data[out_chunk_i]",
    "chunk_wr_data[CHUNK_WIDTH*out_chunk_i +: CHUNK_WIDTH]",
  )
  rtl_text = rtl_text.replace(
    "in_chunk_wr_dst_oh[in_chunk_i][out_chunk_i]",
    "in_chunk_wr_dst_oh[BUFFER_CAPACITY_CHUNKS*in_chunk_i+out_chunk_i]",
  )
  rtl_text = rtl_text.replace(
    "assign in_chunk_wr_dst_oh[in_chunk_i] =",
    "assign in_chunk_wr_dst_oh[BUFFER_CAPACITY_CHUNKS*in_chunk_i +: BUFFER_CAPACITY_CHUNKS] =",
  )
  rtl_text = rtl_text.replace(
    "out_chunk_rd_src_oh[out_chunk_i][buffer_chunk_i]",
    "out_chunk_rd_src_oh[BUFFER_CAPACITY_CHUNKS*out_chunk_i+buffer_chunk_i]",
  )
  rtl_text = rtl_text.replace(
    "assign out_chunk_rd_src_oh[out_chunk_i] =",
    "assign out_chunk_rd_src_oh[BUFFER_CAPACITY_CHUNKS*out_chunk_i +: BUFFER_CAPACITY_CHUNKS] =",
  )
  synth_rtl.write_text(rtl_text, encoding="utf-8")

  flatten_arg = " -flatten" if not args.no_flatten else ""
  script_text = f"""
read_liberty -lib {args.liberty.resolve()}
read_verilog -sv -DSYNTHESIS {synth_rtl.resolve()}
hierarchy -check -top gearbox
proc
opt
synth -top gearbox{flatten_arg}
dfflibmap -liberty {args.liberty.resolve()}
abc -liberty {args.liberty.resolve()}
clean
tee -o {stat_report.resolve()} stat -liberty {args.liberty.resolve()}
tee -o {check_report.resolve()} check
write_verilog -noattr {netlist.resolve()}
""".strip()

  synth_script.write_text(script_text + "\n", encoding="utf-8")

  cmd = [yosys_bin, "-s", str(synth_script)]
  print(f"yosys={yosys_bin}")
  print(f"liberty={args.liberty.resolve()}")
  print(f"in_data_width={args.in_data_width}")
  print(f"out_data_width={args.out_data_width}")
  print(f"chunk_width={chunk_width}")
  print(f"build_dir={build_dir.resolve()}")
  subprocess.run(cmd, check=True)
  print(f"wrote {netlist}")
  print(f"wrote {stat_report}")
  print(f"wrote {check_report}")


if __name__ == "__main__":
  main()
