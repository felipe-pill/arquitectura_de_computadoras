`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for store_align.
// Spec (RV32I + docs/arquitectura.md 2.3): the store data is replicated on
// every byte lane and be selects the lanes written:
//   sb (00): be = one-hot lane addr[1:0], wdata = 4 copies of data[7:0]
//   sh (01): be = 0011 (addr[1] = 0) or 1100 (addr[1] = 1), addr[0] ignored,
//            wdata = 2 copies of data[15:0]
//   sw (10): be = 1111, wdata = data, addr[1:0] ignored
//   11:      be = 0000 (never sent by the decoder)

module tb_store_align;

  localparam integer N_RANDOM = 500;

  reg  [1:0]  funct3 = 2'b10;
  reg  [1:0]  addr_lo = 2'd0;
  reg  [31:0] data = 32'd0;
  wire [31:0] wdata;
  wire [3:0]  be;

  store_align dut (.funct3(funct3), .addr_lo(addr_lo), .data(data),
                   .wdata(wdata), .be(be));

  integer errors = 0;
  integer checks = 0;
  integer i, f, a, seed;

  task check;
    input [8*8-1:0] tag;
    input [1:0]     t_f3;
    input [1:0]     t_lo;
    input [31:0]    t_data;
    input [3:0]     exp_be;
    input [31:0]    exp_wdata;
    input           verbose;
    begin
      funct3 = t_f3; addr_lo = t_lo; data = t_data;
      #1;
      checks = checks + 1;
      // With be = 0 nothing is written, so wdata is irrelevant
      if (be === exp_be && (exp_be == 4'b0000 || wdata === exp_wdata)) begin
        if (verbose)
          $display("PASS %0s: funct3=%b addr_lo=%0d data=%08h -> be=%b wdata=%08h",
                   tag, t_f3, t_lo, t_data, be, wdata);
      end else begin
        errors = errors + 1;
        $display("FAIL %0s: funct3=%b addr_lo=%0d data=%08h expected be=%b wdata=%08h got be=%b wdata=%08h  TEST FAILED",
                 tag, t_f3, t_lo, t_data, exp_be, exp_wdata, be, wdata);
      end
    end
  endtask

  initial begin
    // Directed (values from asm/loadstore.s, data = 0x89ABCDEF)
    check("sb0", 2'b00, 2'd0, 32'h89ABCDEF, 4'b0001, 32'hEFEFEFEF, 1'b1);
    check("sb1", 2'b00, 2'd1, 32'h89ABCDEF, 4'b0010, 32'hEFEFEFEF, 1'b1);
    check("sb2", 2'b00, 2'd2, 32'h89ABCDEF, 4'b0100, 32'hEFEFEFEF, 1'b1);
    check("sb3", 2'b00, 2'd3, 32'h89ABCDEF, 4'b1000, 32'hEFEFEFEF, 1'b1);
    check("sh0", 2'b01, 2'd0, 32'h89ABCDEF, 4'b0011, 32'hCDEFCDEF, 1'b1);
    check("sh1", 2'b01, 2'd1, 32'h89ABCDEF, 4'b0011, 32'hCDEFCDEF, 1'b1);  // addr[0] ignored
    check("sh2", 2'b01, 2'd2, 32'h89ABCDEF, 4'b1100, 32'hCDEFCDEF, 1'b1);
    check("sh3", 2'b01, 2'd3, 32'h89ABCDEF, 4'b1100, 32'hCDEFCDEF, 1'b1);
    check("sw0", 2'b10, 2'd0, 32'h89ABCDEF, 4'b1111, 32'h89ABCDEF, 1'b1);
    check("sw2", 2'b10, 2'd2, 32'h89ABCDEF, 4'b1111, 32'h89ABCDEF, 1'b1);  // addr ignored
    check("f3_11", 2'b11, 2'd0, 32'h89ABCDEF, 4'b0000, 32'h00000000, 1'b1);

    // Exhaustive over funct3 and addr_lo, random data
    seed = 2026;
    for (i = 0; i < N_RANDOM; i = i + 1) begin
      data = $random(seed);
      for (a = 0; a < 4; a = a + 1) begin
        check("random", 2'b00, a[1:0], data, 4'b0001 << a, {4{data[7:0]}}, 1'b0);
        check("random", 2'b01, a[1:0], data, a[1] ? 4'b1100 : 4'b0011, {2{data[15:0]}}, 1'b0);
        check("random", 2'b10, a[1:0], data, 4'b1111, data, 1'b0);
        check("random", 2'b11, a[1:0], data, 4'b0000, 32'd0, 1'b0);
      end
    end

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d checks)", checks);
    else
      $fatal(1, "%0d of %0d checks failed", errors, checks);
    $finish;
  end

endmodule

`default_nettype wire
