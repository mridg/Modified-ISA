# RV32I 5‑Stage Processor — Architecture, Build & Extension Guide

This document explains how the repository is organized, how to simulate the core,
how to run the RISC‑V architectural (RISCOF) tests, how to collect cycle/CPI
benchmarks, and exactly where to make changes when you want to add your own
custom instructions.

---

## 1. Repository layout

```
RV32I-5-Stage-Processor/
├── Design/                     Synthesizable RTL (SystemVerilog). This is the CPU.
├── TestBenches/                Simulation testbenches (unit + full datapath)
├── SitarahV/                   RISCOF DUT plugin  ("SitarahV" = the name of this core)
├── spike/                      RISCOF reference-model plugin (Spike ISS)
├── config.ini                  RISCOF config: DUT = SitarahV, reference = spike
├── Instructions.mem, Data.mem  Sample program image for standalone simulation
│                               (ASCII hex, one 32-bit word per line, $readmemh format)
├── MainDatapath.vcd            A captured waveform from a previous run
├── FPGA_Top.bit                Pre-built bitstream for the Digilent Arty A7-100T
├── riscof_test1.png/2.png      Screenshots of a passing RISCOF run
└── docs/                       This guide
```

### 1.1 `Design/` — the RTL, module by module

| File | Stage / role | What it does | Key signals |
|---|---|---|---|
| `RISCV_Config_PKG.sv` | package `RISCV_PKG` | Global parameters: register/word widths (32), `ADDRESS_PORT_WIDTH` (5), memory sizing. Imported by nearly every module via `import RISCV_PKG::*;`. | `REG_WIDTH`, `WORD_LENGTH`, `MEM_ROWS` |
| `MainDatapath.sv` | **top level** | Instantiates the 5 stages, the hazard/forward wiring, and the trace logic. This is the module a testbench drives. Also exposes an RVFI-style retirement interface (`rvfi_o_*`). | `CLK, EN, Reset`, `mem_file_path`, `data_memory_path`, `rvfi_o_*` |
| `InstructionFetch.sv` | **IF** | Holds the `ProgramCounter` + `InstructionMemory`, plus the IF/ID pipeline register. Handles flush (`IF_Flush`) and stall (`RetainPC`, `RetainIF_ID`). Has forwarding muxes so a `jalr` base register can be forwarded into the PC calc. | `Instruction`, `PC`, `PCcomputed` |
| `ProgramCounter.sv` | IF | Next‑PC logic in one expression: sequential `+4`, `jal`/taken‑branch `PC+imm`, `jalr` `rs1+imm`, or hold (`RetainPC`). PC resets to `-4`. | `PC` |
| `InstructionMemory.sv` | IF | `$readmemh(mem_file_path)` into a word array; combinational read at `addr>>2`. | `ReadInstruction` |
| `InstructionDecode.sv` | **ID** | Holds `ControlUnit`, `RegisterFile`, `ImmediateGenerator`, `BranchDecisionUnit`, `HazardDetectionUnit`, plus the ID/EX pipeline register. **Branches are resolved here**, not in EX. Contains the ID‑stage operand‑forwarding muxes (`dataA`/`dataB`). | `ALUOp`, `Func3/7`, `Opcode`, control bits, `ImmediateOutput*` |
| `ControlUnit.sv` | ID | Pure `case(Opcode)` → control signals (`RegWrite`, `MemWrite`, `MemToReg`, `Branch`, `Jump`, `JumpReg`, `RegSrc1/2`, `UpperImm`, `imm`, `RetAddr`, `ALUOp`, `ID_Flush`, `rvfi_i_bool`). Unknown opcode → all zero + `rvfi_i_bool = 0` (treated as a bubble / silently NOP). | `ALUOp[2:0]` |
| `RegisterFile.sv` | ID | 32×32. Asynchronous read, synchronous write, `x0` hardwired to 0. | `ReadData1/2` |
| `ImmediateGenerator.sv` | ID | `case(Opcode)` → sign‑extended 32‑bit immediate for I/S/B/U/J formats. | `ImmediateOutput` |
| `BranchDecisionUnit.sv` | ID | `case({Opcode,Func3})` → `ONE` = "branch taken". Uses the ID‑forwarded `dataA`/`dataB`. | `ONE` |
| `HazardDetectionUnit.sv` | ID | Load‑use interlock: if the instruction in ID/EX is a load (`MemToReg`) whose `rd` matches a source register in IF/ID → `HazardDetected` (one‑cycle stall). | `HazardDetected` |
| `Execute.sv` | **EX** | Holds `ALUControl`, `ALU`, `ForwardingUnit`, plus the EX/MEM pipeline register. Selects ALU `DataA`/`DataB` (register, immediate, PC, `4` for link, or forwarded values). | `ALUResult`, `iALUResult` (combinational) |
| `ALUControl.sv` | EX | `casez({ALUOp, func3, func7[5]})` (7 bits) → 4‑bit `ALUOperation`. This is the decode table that turns the coarse `ALUOp` class into a concrete ALU op. | `ALUOperation[3:0]` |
| `ALU.sv` | EX | `case(ALUOperation)` → result. Implements ADD/SUB/AND/OR/XOR/SLL/SRL/SRA/SLT/SLTU. | `ALUOutput` |
| `ForwardingUnit.sv` | EX | Produces **all** forwarding selects consumed in IF, ID and EX (EX/MEM→EX, MEM/WB→EX, and several paths into ID for the early branch resolution). Compares `rd` of downstream pipeline regs against source regs, guarded by `RegWrite` and `rd != 0`. | `ForwardALU_A/B`, `Forward_*_To_ID_*`, `ForwardMemToRegData_*` |
| `Memory.sv` | **MEM** | Wraps `DataMemory` and the MEM/WB pipeline register. | `ReadData`, `ALUResult`, `mask_bits` |
| `DataMemory.sv` | MEM | `$readmemh(data_memory_path)` word array. Byte/half/word stores and sign/zero‑extended loads decoded from `Funct3`. Produces `mask_bits` (write strobe) used by the tracer. | `ReadData`, `mask_bits` |
| `WriteBack.sv` | **WB** | One mux: `MemToReg ? ReadData : ALUResult`. | `WriteData` |
| `Tracer.sv` | trace | Renames a bundle of internal signals to RVFI‑style output names (`rvfi_o_insn`, `rvfi_o_rd_wdata`, …). Auto‑generated from a Chisel/Scala model — pure wiring. | `rvfi_o_*` |
| `TracerPipelineRegister.sv` | trace | Shifts the retirement info (instruction, reg reads, PC, mem access) down 3 stages so that `rvfi_o_valid` and friends line up with the instruction **at the moment it retires** (used for signature dumping and any RVFI checker). | `rvfi_i_*` |

**Pipeline diagram**

```
        IF                 ID                     EX               MEM        WB
 ┌──────────────┐  ┌────────────────────┐  ┌────────────────┐  ┌─────────┐  ┌──────┐
 │ PC           │  │ ControlUnit        │  │ ALUControl     │  │DataMem  │  │ mux  │
 │ InstrMem     │─▶│ RegFile (read)     │─▶│ ALU            │─▶│ (lb/lh/ │─▶│MemTo │
 │ IF/ID reg    │  │ ImmGen             │  │ ForwardingUnit │  │  lw/sb… │  │ Reg  │
 │              │  │ BranchDecisionUnit │  │ EX/MEM reg     │  │ MEM/WB  │  │      │
 │              │  │ HazardDetectionU.  │  │                │  │  reg    │  │      │
 │              │  │ ID/EX reg          │  │                │  │         │  │      │
 └──────────────┘  └────────────────────┘  └────────────────┘  └─────────┘  └──────┘
        ▲  branch/jump target + flush (ID_Flush) computed in ID → 1-cycle penalty
        └── RegFile write happens from MEM/WB in the same ID module (write-after-read same cycle)
```

**Design characteristics / things to know before you edit**

- **Branch/jump resolution is in ID** (not EX). `ControlUnit` raises `ID_Flush` for
  jumps and taken branches; the penalty is one bubble. Extra forwarding paths
  (`Forward_*_To_ID_A/B`) exist to feed operands into the ID‑stage comparator.
- **Only load‑use causes a stall.** Everything else is handled by forwarding.
- **No CSRs, no traps, no interrupts, no `fence`, no misalignment checks, no M/A/F/D.**
  Undefined opcodes decode to a bubble (`rvfi_i_bool = 0`) rather than trapping.
- Memories are behavioral `$readmemh` arrays indexed by `address >> 2`. They are
  huge (`MEM_ROWS = 1<<25`) — fine for simulation, not synthesized as‑is for FPGA.
- `ALUOp[2:0]` is the *class* (see table below). `ALUControl` turns
  `{ALUOp, funct3, funct7[5]}` into the concrete 4‑bit `ALUOperation`.

**`ALUOp` class encoding (set in `ControlUnit.sv`)**

| `ALUOp` | Meaning | Instructions |
|---|---|---|
| `000` | I‑type arithmetic | `addi, slti, sltiu, xori, ori, andi, slli, srli, srai` |
| `001` | store address (add) | `sb, sh, sw` |
| `010` | upper immediate (add) | `lui, auipc` |
| `011` | branch (ALU result unused; compare is in ID) | `beq…bgeu` |
| `100` | link / jump address (add) | `jal, jalr` |
| `101` | R‑type | `add, sub, sll, slt, sltu, xor, srl, sra, or, and` |
| `110` | load address (add) | `lb, lh, lw, lbu, lhu` |
| `111` | **free — use this for your custom class** | — |

**`ALUOperation[3:0]` encoding (in `ALUControl.sv` → `ALU.sv`)**

| code | op | code | op |
|---|---|---|---|
| `0000` | OR   | `1000` | SLL |
| `0001` | AND  | `1001` | XOR |
| `0010` | ADD  | `1010` | SRL |
| `0011` | SUB  | `1011` | SRA |
| `0101` | SLT  | `1101` | SLTU |
| `1111` | (default → 0) | free: `0100 0110 0111 1100 1110` | — |

### 1.2 `TestBenches/`

| File | Drives | Notes |
|---|---|---|
| `MainDatapath_TestBench.sv` | `MainDatapath` | **The important one.** Reads `+MEMFILE=<hex>` and `+DMEMFILE=<hex>` plusargs, clocks the core, and on each retired store watches the RVFI outputs: a word written to `0x8004` is printed as a signature line; a write of `0xCAFECAFE` to `0x8008` ends the sim (`$finish`). Also a 900 000‑cycle watchdog. Dumps `MainDatapath.vcd`. |
| `ALU_TestBench.sv`, `ALUControl_TestBench.sv`, `ControlUnit_TestBench.sv`, `ImmediateGen_TestBench.sv`, `ProgramCounter_TestBench.sv`, `RegisterFile_TestBench.sv`, `MainMemory_TestBench.sv` | individual modules | Handy references for module interfaces. Some are **stale** (e.g. `ALU_TestBench` references an `ONE` port the ALU no longer has) — treat them as documentation, fix before use. |

### 1.3 `SitarahV/` — the RISCOF DUT plugin

RISCOF ("RISC‑V Compatibility Framework") compiles each architectural test twice —
once for your DUT, once for the reference model (Spike) — runs both, and diffs a
"signature" region of memory.

| File | Purpose |
|---|---|
| `riscof_SitarahV.py` | The plugin. For every test it: `riscv…-gcc` compile → `objcopy` `.text.init` and `.data` to binary → `hexdump` to `imem.hex`/`dmem.hex` → `verilator --binary` build of `MainDatapath_TestBench` → run with `+MEMFILE/+DMEMFILE` → stdout becomes `DUT-SitarahV.signature` → post‑process with the two `env/*.py` scripts. |
| `SitarahV_isa.yaml` | `ISA: RV32I`, `supported_xlen: [32]`. Controls which tests RISCOF selects. |
| `SitarahV_platform.yaml` | reset / nmi labels. |
| `env/link.ld` | Linker script for DUT builds: `.text` at `0x0000_0000` (ICCM), `.data` at `0x0800_0000` (DCCM). |
| `env/model_test.h` | The `RVMODEL_*` macros the tests expand. `RVMODEL_HALT` copies `begin_signature..end_signature` word‑by‑word to `0x8000004` (each word triggers the testbench's "print signature line"), then stores `0xCAFECAFE` to `0x8000008` to stop the sim. |
| `env/lines_remover.py` | Strips the last 4 lines of the raw signature file. |
| `env/extra_signature_remover.py` | Keeps only the first 36 lines. |

> ⚠️ **The plugin is not portable as committed.** It has hard‑coded paths
> (`/home/mahmed/Documents/SitarahV/...`), assumes `riscv32-unknown-elf-gcc`
> (this machine has `riscv64-unknown-elf-gcc` with multilib), and its last
> post‑processing command points at a specific `jal-01.S` signature path. See
> §3.2 for the edits needed.

### 1.4 `spike/` — the RISCOF reference plugin

Standard RISCOF Spike plugin. `env/link.ld` puts code at `0x8000_0000`;
`env/model_test.h`'s `RVMODEL_HALT` writes to `tohost`. You normally don't touch this.

---

## 2. Running the core standalone (one program)

### 2.1 Toolchain status on this machine

| Tool | Present? | Notes |
|---|---|---|
| `iverilog` | ✅ | **Does not compile this design** — chokes on the SV package declaration. Not recommended. |
| `verilator` | ❌ | `brew install verilator` — this is what the project targets. |
| `spike` | ✅ | RISC‑V reference ISS. |
| `riscv64-unknown-elf-gcc` | ✅ | Multilib; build rv32 with `-march=rv32i -mabi=ilp32`. |
| `riscof` (pip) | ❌ | `pip install riscof` inside a venv. |
| `qemu-system-riscv32/64` | ✅ | Not needed for this flow. |

### 2.2 Build + run with Verilator

Use the helper script `scripts/sim.sh` (added with this guide). It lists the RTL
in the right order (package first), applies the lint waivers this code needs, and
builds `--binary --timing --trace`:

```bash
brew install verilator          # v5.x; 5.052 is known good

# <top-module>  then any +plusargs, run from the repo root:
scripts/sim.sh MainDatapath_TestBench +MEMFILE=Instructions.mem +DMEMFILE=Data.mem
```

Expected output — the bundled sample **does** halt (it ends with the `0xCAFECAFE`
marker); the `00000047 / 0000003b …` lines are its signature dump:

```
00000000
00000047
0000003b
...
- TestBenches/MainDatapath_TestBench.sv:73: Verilog $finish
- Verilator: $finish at 3us
```

- The bundled `Instructions.mem` is a RISC‑V architectural test (the `jal‑01`
  test — 1230 instructions), already in `$readmemh` format (one hex word / line).
- Build artifacts land in `./obj_dir/` (git‑ignored). The run writes/overwrites
  `MainDatapath.vcd` **in the repo root** (a stale copy of that file is committed;
  `git checkout -- MainDatapath.vcd` to discard a re‑generated one). Open it with
  `gtkwave` / Surfer.
- Gotcha: Verilator treats a `//`‑comment line whose first word is `verilator` as
  a pragma. Don't start comment lines with that word in any `.sv` file you add.

### 2.3 Making your own test program

1. Write assembly (or C) and link with the DUT linker script:
   ```bash
   riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
     -T SitarahV/env/link.ld -o prog.elf prog.S
   ```
2. Extract and hex‑dump the two segments the memories load:
   ```bash
   riscv64-unknown-elf-objcopy -O binary -j .text.init -j .text prog.elf imem.bin
   riscv64-unknown-elf-objcopy -O binary -j .data              prog.elf dmem.bin
   hexdump -v -e '1/4 "%08x\n"' imem.bin > imem.hex
   hexdump -v -e '1/4 "%08x\n"' dmem.bin > dmem.hex
   ```
3. End the program with a store of `0xCAFECAFE` to `0x08000008`… **but note** the
   testbench currently checks address `0x8008`/`0x8004` (not `0x08000008`). The
   RISCOF `model_test.h` works because `RVMODEL_HALT` loads `li a2, 0x8000004`
   which truncates in the DUT's small address space. For hand‑written tests, match
   whatever the testbench watches, or (better) add an explicit "instructions
   retired" counter — see §4.

---

## 3. Running the RISC‑V architectural tests (RISCOF)

### 3.1 One‑time setup

```bash
python3 -m venv .venv
source .venv/bin/activate.fish        # you use fish; for bash: source .venv/bin/activate
pip install riscof
brew install verilator

# Clone the official arch-test suite (goes into ./riscv-arch-test, already gitignored)
riscof --verbose info arch-test --clone
```

### 3.2 Fix the DUT plugin (`SitarahV/riscof_SitarahV.py`)

Required edits before it will run here:

1. **Hard‑coded paths.** Replace every `/home/mahmed/Documents/SitarahV` with a
   path derived at runtime. `self.pluginpath` is `.../SitarahV`; the repo root is
   its parent. e.g. near the top of `runTests`:
   ```python
   repo_root = os.path.dirname(self.pluginpath)
   design_dir = os.path.join(repo_root, 'Design')
   tb = os.path.join(repo_root, 'TestBenches', 'MainDatapath_TestBench.sv')
   ```
   and use those in the `verilator` command instead of the absolute strings.
2. **Compiler name.** `self.compile_cmd` / `self.objcopy` use `riscv{0/1}-unknown-elf-…`
   with xlen `32` → `riscv32-unknown-elf-*`. Change the template to
   `riscv64-unknown-elf-*` (multilib builds rv32 fine with the existing
   `-march=rv32i… -mabi=ilp32`).
3. **The stray last command.** The final line of the `simcmd` tuple runs
   `extra_signature_remover.py` against a hard‑coded `jal-01.S` path. Change it to
   operate on `sig_file` (the current test's signature).
4. **Verilator invocation.** Prefer building into the per‑test `work_dir`
   (`--Mdir`), and confirm the produced binary name
   (`obj_dir/VMainDatapath_TestBench`) matches what the run line expects.

### 3.3 Run

```bash
source .venv/bin/activate.fish
riscof run --config=config.ini \
  --suite=riscv-arch-test/riscv-test-suite/rv32i_m \
  --env=riscv-arch-test/riscv-test-suite/env
```

Output: `riscof_work/report.html` (green = DUT signature matched Spike). The two
`riscof_test*.png` files in the repo are what a passing run looks like.

RISCOF is **correctness**, not performance — but the per‑test compiled ELFs are a
convenient corpus to run through the cycle counter in the next section.

---

## 4. Collecting benchmarks (cycles / IPC / CPI)

The core exposes a clean retirement signal: **`rvfi_o_valid_0` pulses once per
retired instruction**, so instructions‑retired = count of cycles where it's high.
`TestBenches/Benchmark_TestBench.sv` (added with this guide) counts cycles + retires
and prints CPI:

```bash
scripts/sim.sh Benchmark_TestBench +MEMFILE=Instructions.mem +DMEMFILE=Data.mem
```
```
=== benchmark done ===
cycles          = 1374
instr retired   = 1230
CPI             = 1.1171   (IPC = 0.8952)
```

That 1.12 CPI on the `jal‑01` test is jump/branch‑heavy (each taken control‑flow
op costs a 1‑cycle ID‑stage bubble); straight‑line ALU code sits near 1.0.

### 4.1 The testbench (for reference — already in the repo)

```systemverilog
// Cycle / instruction / CPI counter for the 5-stage core.
// Run:  ./obj_dir/VBenchmark_TestBench +MEMFILE=imem.hex +DMEMFILE=dmem.hex
module Benchmark_TestBench;
    logic CLK = 0, Reset = 1, EN = 1;
    string mem_file_path, data_memory_path;

    // RVFI outputs
    logic        rvfi_o_valid_0;
    logic [31:0] rvfi_o_insn_0, rvfi_o_pc_rdata_0, rvfi_o_pc_wdata_0;
    logic [31:0] rvfi_o_mem_addr_0, rvfi_o_mem_wdata_0, rvfi_o_mem_rdata_0;
    logic [31:0] rvfi_o_rs1_rdata_0, rvfi_o_rs2_rdata_0, rvfi_o_rd_wdata_0;
    logic [4:0]  rvfi_o_rs1_addr_0, rvfi_o_rs2_addr_0, rvfi_o_rd_addr_0;
    logic [3:0]  rvfi_o_mem_wmask_0;

    MainDatapath uut (.CLK(CLK), .EN(EN), .Reset(Reset),
        .mem_file_path(mem_file_path), .data_memory_path(data_memory_path),
        .rvfi_o_valid_0(rvfi_o_valid_0), .rvfi_o_insn_0(rvfi_o_insn_0),
        .rvfi_o_rs1_addr_0(rvfi_o_rs1_addr_0), .rvfi_o_rs2_addr_0(rvfi_o_rs2_addr_0),
        .rvfi_o_rs1_rdata_0(rvfi_o_rs1_rdata_0), .rvfi_o_rs2_rdata_0(rvfi_o_rs2_rdata_0),
        .rvfi_o_rd_addr_0(rvfi_o_rd_addr_0), .rvfi_o_rd_wdata_0(rvfi_o_rd_wdata_0),
        .rvfi_o_pc_rdata_0(rvfi_o_pc_rdata_0), .rvfi_o_pc_wdata_0(rvfi_o_pc_wdata_0),
        .rvfi_o_mem_addr_0(rvfi_o_mem_addr_0), .rvfi_o_mem_wmask_0(rvfi_o_mem_wmask_0),
        .rvfi_o_mem_rdata_0(rvfi_o_mem_rdata_0), .rvfi_o_mem_wdata_0(rvfi_o_mem_wdata_0));

    always #1 CLK = ~CLK;

    longint unsigned cycles = 0, retired = 0;

    initial begin
        if (!$value$plusargs("MEMFILE=%s",  mem_file_path))  $fatal(1, "no +MEMFILE");
        if (!$value$plusargs("DMEMFILE=%s", data_memory_path)) $fatal(1, "no +DMEMFILE");
        #2 Reset = 0;
    end

    always @(posedge CLK) begin
        if (!Reset) begin
            cycles++;
            if (rvfi_o_valid_0) retired++;

            // end-of-program marker (same convention as MainDatapath_TestBench)
            if (rvfi_o_valid_0 && rvfi_o_mem_wmask_0 == 4'b1111 &&
                rvfi_o_mem_addr_0 == 32'h8008 && rvfi_o_mem_wdata_0 == 32'hCAFECAFE) begin
                $display("cycles=%0d  retired=%0d  CPI=%0.3f  IPC=%0.3f",
                         cycles, retired, real'(cycles)/retired, real'(retired)/cycles);
                $finish;
            end
            if (cycles > 5_000_000) begin
                $display("WATCHDOG cycles=%0d retired=%0d", cycles, retired);
                $finish;
            end
        end
    end
endmodule
```

Build it the same way as §2.2 (swap the top module and the last file). Then feed
it any `imem.hex`/`dmem.hex` pair built as in §2.3.

### 4.2 What to benchmark

- **Microbenchmarks**: Dhrystone, CoreMark, or the individual
  [Embench‑IOT](https://github.com/embench/embench-iot) kernels, compiled
  `-march=rv32i -mabi=ilp32 -O2 -nostdlib` with a tiny `crt0.S` (set `sp`, call
  `main`, then store `0xCAFECAFE` to `0x8008`). RV32I‑only (no `mul`/`div`) means
  `-mno-...`; gcc emits `__mulsi3` etc. from libgcc — link `-lgcc` or
  `--specs=nano.specs` won't apply (no newlib startup); simplest is to add
  `libgcc.a`'s path explicitly.
- **Hazard stress**: hand‑written loops of dependent `lw`/`add` to measure the
  load‑use stall rate.
- **Metrics the harness gives you**: total cycles, retired instructions, CPI, and
  (with a few counters added to the testbench) stall cycles and flush cycles.

Because IF/EX/MEM are single‑cycle and branches cost 1 bubble, expect CPI ≈
1.0–1.3 on straight‑line code, higher with branch‑ and load‑heavy code.

---

## 5. Adding a custom instruction — where to edit

### 5.1 The general checklist

A new instruction touches the pipeline at these points, in order:

| # | File | Change | Needed when |
|---|---|---|---|
| 1 | `ControlUnit.sv` | New `case(Opcode)` arm (or new `funct3`/`funct7` sub‑decode) producing the control bits + an `ALUOp` class. Set `rvfi_i_bool = 1`. | always |
| 2 | `ImmediateGenerator.sv` | New `case(Opcode)` arm if the instruction uses an immediate whose bit layout isn't already one of I/S/B/U/J. | new immediate format |
| 3 | `ALUControl.sv` | New `casez` arm mapping `{ALUOp,funct3,funct7[5]}` → a (new) 4‑bit `ALUOperation`. Put specific arms *above* the wildcard ADD line (casez is priority‑ordered). | new datapath compute |
| 4 | `ALU.sv` | New `case(ALUOperation)` arm implementing the operation. | new datapath compute |
| 5 | `Execute.sv` | Extend the `DataA`/`DataB` select `always_comb` if the operands aren't "rs1 / rs2‑or‑immediate" (e.g. needs PC, a 3rd operand, shifted value…). | non‑standard operands |
| 6 | `InstructionDecode.sv` + `MainDatapath.sv` | Add register read ports / widen the ID/EX pipeline register if you need a 3rd source register or extra decoded fields carried down the pipe. | 3rd operand, extra state |
| 7 | `ForwardingUnit.sv` / `HazardDetectionUnit.sv` | Add comparisons for any new source register so forwarding & load‑use stalls still work. | new source register |
| 8 | `BranchDecisionUnit.sv` + `ProgramCounter.sv` | New control‑flow condition / target math. | new branch/jump |
| 9 | `Memory.sv` / `DataMemory.sv` | New access size / addressing / atomic behavior. | new load/store |
| 10 | `TracerPipelineRegister.sv` / `Tracer.sv` | Only if the instruction's retirement semantics (rd write, mem access) need to appear on the RVFI trace differently. | RVFI correctness for compliance |
| 11 | a testbench + a `.S` test | Directed test. gas won't know your mnemonic — emit it with `.insn` or `.word`. | always |

### 5.2 Worked example — a custom R‑type `PCNT rd, rs1` (population count)

Uses the RISC‑V **`custom‑0`** major opcode `0b0001011` (`0x0B`), R‑type layout,
`funct3 = 000`, `funct7 = 0000000`. Reads `rs1`, ignores `rs2`, writes `rd`.

**1. `ControlUnit.sv`** — add before `default:`:
```systemverilog
7'b0001011: begin           // custom-0, R-type
    JumpReg=0; Jump=0; Branch=0;
    RegSrc1=1;               // read rs1
    RegSrc2=0;               // rs2 unused
    UpperImm=0; RetAddr=0;
    RegWrite=1; MemWrite=0; MemToReg=0;
    imm=0;
    ALUOp=3'b111;            // the free custom class
    ID_Flush=0;
    rvfi_i_bool=1;
end
```

**2. `ImmediateGenerator.sv`** — not needed (no immediate).

**3. `ALUControl.sv`** — add as the first arm inside the `casez` (so it beats the
`7'b111????` ADD wildcard):
```systemverilog
7'b1110000: ALUOperation = 4'b0100;   // custom class + funct3=000 → PCNT
```

**4. `ALU.sv`** — add an arm:
```systemverilog
4'b0100: ALUOutput = $countones(dataA);   // population count of rs1
```
(`dataB` is 0 here since `RegSrc2=0` and `imm=0` — check `Execute.sv`'s `DataB`
mux; with `imm=0`, `RetAddr=0`, `RegSrc2=0` it stays `0`, which is fine.)

**5–10.** Not needed: standard R‑type operands, single‑cycle, writes `rd` in WB
like any ALU op, no new control flow, no memory. Forwarding already works because
`rd`/`rs1` come from the normal instruction fields.

**11. Test** (`test/pcnt.S`), emitting the raw encoding:
```asm
.section .text.init
.global rvtest_entry_point
rvtest_entry_point:
    li   x1, 0xF0F0F0F0
    # pcnt x2, x1   -> .insn r opcode, funct3, funct7, rd, rs1, rs2
    .insn r 0x0B, 0x0, 0x00, x2, x1, x0     # x2 should become 16
    li   x3, 0x08000008
    li   x4, 0xCAFECAFE
    sw   x4, 0(x3)                          # stop the testbench
1:  j 1b
```
Build per §2.3, run the §4.1 benchmark TB or add a checker that inspects
`rvfi_o_rd_wdata_0` when `rvfi_o_insn_0[6:0] == 7'h0B`.

### 5.3 If your instruction is multi‑cycle (e.g. a real multiplier, divide)

- Add the functional unit in `Execute.sv`.
- Add a "busy" output and feed it into `HazardDetectionUnit.sv` (or a new stall
  source) so `RetainPC`/`RetainIF_ID` hold the front of the pipe while it works.
- The EX/MEM register must not latch until the unit is done.
- Consider whether the result needs a forwarding path (it already will if it lands
  in `iALUResult`/`ALUResult`).

### 5.4 If you're adding CSRs / traps

That's a larger change: a new CSR file module in ID or a dedicated stage, an
exception path that redirects the PC and squashes younger instructions, and
`mepc`/`mcause`/`mtvec` plumbing. The `ControlUnit` `default` (currently a silent
bubble) is where "illegal instruction" detection would hook in.

---

## 6. Suggested first steps

1. `brew install verilator`, then run §2.2 to get a waveform from the sample
   program — confirms your toolchain.
2. Add `TestBenches/Benchmark_TestBench.sv` (§4.1), write a 20‑line assembly loop,
   and get a cycles/CPI number out.
3. Do the §5.2 `PCNT` example end‑to‑end. It touches 4 files and nothing subtle,
   so it's the cleanest way to learn the decode→ALU path.
4. Only then tackle the RISCOF plugin cleanup (§3.2) if you want regression
   coverage, or a multi‑cycle unit (§5.3) for something more ambitious.
```
