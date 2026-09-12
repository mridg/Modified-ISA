// Cycle / instruction / CPI counter for the RV32I 5-stage core.
//
// Build + run with the helper script (from repo root):
//   scripts/sim.sh Benchmark_TestBench +MEMFILE=imem.hex +DMEMFILE=dmem.hex
//
// The program is expected to end with a store of 0xCAFECAFE to address 0x8008
// (same convention as MainDatapath_TestBench / the SitarahV RVMODEL_HALT macro).

module Benchmark_TestBench;
    logic CLK = 0, Reset = 1, EN = 1;
    string mem_file_path, data_memory_path;

    logic        rvfi_o_valid_0;
    logic [31:0] rvfi_o_insn_0, rvfi_o_pc_rdata_0, rvfi_o_pc_wdata_0;
    logic [31:0] rvfi_o_mem_addr_0, rvfi_o_mem_wdata_0, rvfi_o_mem_rdata_0;
    logic [31:0] rvfi_o_rs1_rdata_0, rvfi_o_rs2_rdata_0, rvfi_o_rd_wdata_0;
    logic [4:0]  rvfi_o_rs1_addr_0, rvfi_o_rs2_addr_0, rvfi_o_rd_addr_0;
    logic [3:0]  rvfi_o_mem_wmask_0;

    MainDatapath uut (
        .CLK(CLK), .EN(EN), .Reset(Reset),
        .mem_file_path(mem_file_path), .data_memory_path(data_memory_path),
        .rvfi_o_valid_0(rvfi_o_valid_0), .rvfi_o_insn_0(rvfi_o_insn_0),
        .rvfi_o_rs1_addr_0(rvfi_o_rs1_addr_0), .rvfi_o_rs2_addr_0(rvfi_o_rs2_addr_0),
        .rvfi_o_rs1_rdata_0(rvfi_o_rs1_rdata_0), .rvfi_o_rs2_rdata_0(rvfi_o_rs2_rdata_0),
        .rvfi_o_rd_addr_0(rvfi_o_rd_addr_0), .rvfi_o_rd_wdata_0(rvfi_o_rd_wdata_0),
        .rvfi_o_pc_rdata_0(rvfi_o_pc_rdata_0), .rvfi_o_pc_wdata_0(rvfi_o_pc_wdata_0),
        .rvfi_o_mem_addr_0(rvfi_o_mem_addr_0), .rvfi_o_mem_wmask_0(rvfi_o_mem_wmask_0),
        .rvfi_o_mem_rdata_0(rvfi_o_mem_rdata_0), .rvfi_o_mem_wdata_0(rvfi_o_mem_wdata_0)
    );

    always #1 CLK = ~CLK;

    longint unsigned cycles = 0, retired = 0;

    initial begin
        if (!$value$plusargs("MEMFILE=%s",  mem_file_path))   $fatal(1, "no +MEMFILE");
        if (!$value$plusargs("DMEMFILE=%s", data_memory_path)) $fatal(1, "no +DMEMFILE");
        #2 Reset = 0;
    end

    always @(posedge CLK) begin
        if (!Reset) begin
            cycles++;
            if (rvfi_o_valid_0) retired++;

            if (rvfi_o_valid_0 && rvfi_o_mem_wmask_0 == 4'b1111 &&
                rvfi_o_mem_addr_0 == 32'h8008 && rvfi_o_mem_wdata_0 == 32'hCAFECAFE) begin
                $display("=== benchmark done ===");
                $display("cycles          = %0d", cycles);
                $display("instr retired   = %0d", retired);
                if (retired != 0)
                    $display("CPI             = %0.4f   (IPC = %0.4f)",
                             real'(cycles) / real'(retired), real'(retired) / real'(cycles));
                $finish;
            end

            if (cycles > 5_000_000) begin
                $display("WATCHDOG: cycles=%0d retired=%0d (no 0xCAFECAFE halt seen)",
                         cycles, retired);
                $finish;
            end
        end
    end
endmodule
