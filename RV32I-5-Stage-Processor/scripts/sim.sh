#!/usr/bin/env bash
# Build + run a Verilator simulation of the RV32I 5-stage core.
#
# Usage:
#   scripts/sim.sh <top-module> [+plusarg ...]
#
# Examples:
#   scripts/sim.sh MainDatapath_TestBench +MEMFILE=Instructions.mem +DMEMFILE=Data.mem
#   scripts/sim.sh Benchmark_TestBench    +MEMFILE=Instructions.mem +DMEMFILE=Data.mem
#
# Produces obj_dir/ and (for MainDatapath_TestBench) MainDatapath.vcd in the CWD.
set -euo pipefail

TOP="${1:?usage: scripts/sim.sh <top-module> [+plusargs...]}"
shift || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# RTL: package first, then every other module, then the requested testbench.
RTL=(Design/RISCV_Config_PKG.sv)
for f in Design/*.sv; do
  [[ "$f" == Design/RISCV_Config_PKG.sv ]] && continue
  RTL+=("$f")
done
RTL+=("TestBenches/${TOP}.sv")

WAIVERS=(-Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-CASEOVERLAP
         -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKANDNBLK -Wno-IMPLICIT
         -Wno-SYMRSVDWORD -Wno-UNSIGNED -Wno-CMPCONST)

verilator --binary --timing --trace -j 0 \
  "${WAIVERS[@]}" \
  --top-module "$TOP" \
  "${RTL[@]}"

exec "./obj_dir/V${TOP}" "$@"
