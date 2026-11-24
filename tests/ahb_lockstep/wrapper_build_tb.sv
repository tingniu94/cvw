// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Build/elaboration only. This binary is NOT run as a dual-core program test.
module wrapper_build_tb;
  import cvw::*;
  `include "config.vh"
  `include "parameter-defs.vh"
  logic  clk;
  logic  reset_ext;
  logic  reset;
  logic [P.AHBW-1:0] HRDATAEXT;
  logic  HREADYEXT,HRESPEXT;
  logic  HSELEXT;
  logic  ExternalStall;
  logic  HCLK,HRESETn;
  logic [P.PA_BITS-1:0] HADDR;
  logic [P.AHBW-1:0] HWDATA;
  logic [P.XLEN/8-1:0] HWSTRB;
  logic  HWRITE;
  logic [2:0] HSIZE;
  logic [2:0] HBURST;
  logic [3:0] HPROT;
  logic [1:0] HTRANS;
  logic  HMASTLOCK;
  logic  HREADY;
  logic  TIMECLK;
  logic [31:0] GPIOIN;
  logic [31:0] GPIOOUT;
  logic [31:0] GPIOEN;
  logic  UARTSin;
  logic  UARTSout;
  logic  SPIIn;
  logic  SPIOut;
  logic [3:0] SPICS;
  logic  SPICLK;
  logic  SDCIn;
  logic  SDCCmd;
  logic [3:0] SDCCS;
  logic  SDCCLK;
  logic [3:0] PWMGPIO;
  logic  fault_valid;
  logic [10:0] compare_fault_reason;
  logic [2:0] gate_fault;
  logic [31:0] owner_seq;
  logic  authorized_dispatch,down_accept,down_complete;
  logic [63:0] pairing_wait_cycles,a_peer_wait_cycles,b_peer_wait_cycles,pair_backpressure_cycles,paired_requests;
  wallylockstepsoc #(P) dut(.clk,.reset_ext,.reset,.HRDATAEXT,.HREADYEXT,.HRESPEXT,.HSELEXT,.ExternalStall,.HCLK,.HRESETn,.HADDR,.HWDATA,.HWSTRB,.HWRITE,.HSIZE,.HBURST,.HPROT,.HTRANS,.HMASTLOCK,.HREADY,.TIMECLK,.GPIOIN,.GPIOOUT,.GPIOEN,.UARTSin,.UARTSout,.SPIIn,.SPIOut,.SPICS,.SPICLK,.SDCIn,.SDCCmd,.SDCCS,.SDCCLK,.PWMGPIO,.fault_valid,.compare_fault_reason,.gate_fault,.owner_seq,.authorized_dispatch,.down_accept,.down_complete,.pairing_wait_cycles,.a_peer_wait_cycles,.b_peer_wait_cycles,.pair_backpressure_cycles,.paired_requests);
  initial begin
    clk='0;
    reset_ext='0;
    HRDATAEXT='0;
    HREADYEXT='0;
    HRESPEXT='0;
    ExternalStall='0;
    TIMECLK='0;
    GPIOIN='0;
    UARTSin='0;
    SPIIn='0;
    SDCIn='0;
    reset_ext=1;UARTSin=1;HREADYEXT=1;
    $dumpfile("wrapper-build.fst");$dumpvars;
    #10000;$fatal(1,"Build-only harness must not be used for program execution");
  end
  always #5 clk=~clk;
  assert property (@(posedge clk) dut.core.ebu.ebu.HREADY==dut.A_HREADY &&
    dut.core_b.ebu.ebu.HREADY==dut.B_HREADY);
endmodule
