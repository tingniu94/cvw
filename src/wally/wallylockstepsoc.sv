///////////////////////////////////////////
// wally-pipelinedsoc.sv
//
// Written: David_Harris@hmc.edu 6 November 2020
// Modified:
//
// Purpose: Dual lockstep wrapper; original cores and one original uncore.
//
// Documentation: RISC-V System on Chip Design
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// Copyright (C) 2021-23 Harvey Mudd College & Oklahoma State University
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may not use this file
// except in compliance with the License, or, at your option, the Apache License version 2.0. You
// may obtain a copy of the License at
//
// https://solderpad.org/licenses/SHL-2.1/
//
// Unless required by applicable law or agreed to in writing, any work distributed under the
// License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
// either express or implied. See the License for the specific language governing permissions
// and limitations under the License.
////////////////////////////////////////////////////////////////////////////////////////////////

module wallylockstepsoc import cvw::*; #(parameter cvw_t P)  (
  input  logic                clk,
  input  logic                reset_ext,        // external asynchronous reset pin
  output logic                reset,            // reset synchronized to clk to prevent races on release
  // AHB Interface
  input  logic [P.AHBW-1:0]   HRDATAEXT,
  input  logic                HREADYEXT, HRESPEXT,
  output logic                HSELEXT,
  // fpga debug signals
  input  logic                ExternalStall,
  // outputs to external memory, shared with uncore memory
  output logic                HCLK, HRESETn,
  output logic [P.PA_BITS-1:0]  HADDR,
  output logic [P.AHBW-1:0]     HWDATA,
  output logic [P.XLEN/8-1:0]   HWSTRB,
  output logic                HWRITE,
  output logic [2:0]          HSIZE,
  output logic [2:0]          HBURST,
  output logic [3:0]          HPROT,
  output logic [1:0]          HTRANS,
  output logic                HMASTLOCK,
  output logic                HREADY,
  // I/O Interface
  input  logic                TIMECLK,          // optional for CLINT MTIME counter
  input  logic [31:0]         GPIOIN,           // inputs from GPIO
  output logic [31:0]         GPIOOUT,          // output values for GPIO
  output logic [31:0]         GPIOEN,           // output enables for GPIO
  input  logic                UARTSin,          // UART serial data input
  output logic                UARTSout,         // UART serial data output
  input  logic                SPIIn,            // SPI pins in
  output logic                SPIOut,           // SPI pins out
  output logic [3:0]          SPICS,            // SPI chip select pins
  output logic                SPICLK,           // SPI clock
  input  logic                SDCIn,            // SDC DATA[0]     to     SPI DI
  output logic                SDCCmd,           // SDC CMD         from   SPI DO
  output logic [3:0]          SDCCS,            // SDC Card Detect from   SPI CS
  output logic                SDCCLK,           // SDC Clock       from   SPI Clock
  output logic [3:0]          PWMGPIO,
  output logic fault_valid,
  output logic [10:0] compare_fault_reason,
  output logic [2:0] gate_fault,
  output logic [31:0] owner_seq,
  output logic authorized_dispatch, down_accept, down_complete,
  output logic [63:0] pairing_wait_cycles, a_peer_wait_cycles, b_peer_wait_cycles,
                      pair_backpressure_cycles, paired_requests
);

  // Uncore signals
  logic [P.AHBW-1:0]          HRDATA;           // from AHB mux in uncore
  logic                       HRESP;            // response from AHB
  logic                       MTimerInt, MSwInt;// timer and software interrupts from CLINT
  logic [63:0]                MTIME_CLINT;      // from CLINT to CSRs
  logic                       MExtInt,SExtInt;  // from PLIC

  // synchronize reset to SOC clock domain
  synchronizer resetsync(.clk, .d(reset_ext), .q(reset));

  // Two replicas of one logical hart; original cores and memories are unchanged.
  logic [P.PA_BITS-1:0]       A_HADDR;
  logic [P.AHBW-1:0]          A_HWDATA, A_HRDATA;
  logic [P.XLEN/8-1:0]        A_HWSTRB;
  logic                       A_HWRITE, A_HMASTLOCK, A_HREADY, A_HRESP;
  logic [2:0]                 A_HSIZE, A_HBURST;
  logic [3:0]                 A_HPROT;
  logic [1:0]                 A_HTRANS;

  logic [P.PA_BITS-1:0]       B_HADDR;
  logic [P.AHBW-1:0]          B_HWDATA, B_HRDATA;
  logic [P.XLEN/8-1:0]        B_HWSTRB;
  logic                       B_HWRITE, B_HMASTLOCK, B_HREADY, B_HRESP;
  logic [2:0]                 B_HSIZE, B_HBURST;
  logic [3:0]                 B_HPROT;
  logic [1:0]                 B_HTRANS;

  logic A_HCLK, A_HRESETn, B_HCLK, B_HRESETn;
  logic A_pending_valid, B_pending_valid, A_req_valid, B_req_valid;
  logic pair_valid, pair_ready, match_valid, match_ready, policy_reject;
  logic address_phase, data_phase, response_pending;
  logic A_complete, B_complete, A_rsp_capture, B_rsp_capture;
  assign HCLK = clk;
  assign HRESETn = ~reset;
  initial assert(P.BUS_SUPPORTED && P.AHBW==64 && P.XLEN==64 &&
    P.BURST_EN && P.ICACHE_LINELENINBITS==512 && P.DCACHE_LINELENINBITS==512)
    else $fatal(1,"Initial dual wrapper supports rv64gc INCR8 only");
  assert property (@(posedge clk) A_HCLK==HCLK && B_HCLK==HCLK &&
    A_HRESETn==HRESETn && B_HRESETn==HRESETn);
  wallypipelinedcore #(P) core(.clk, .reset,
    .MTimerInt, .MExtInt, .SExtInt, .MSwInt, .MTIME_CLINT, .ExternalStall,
    .HRDATA(A_HRDATA), .HREADY(A_HREADY), .HRESP(A_HRESP),
    .HCLK(A_HCLK), .HRESETn(A_HRESETn),
    .HADDR(A_HADDR), .HWDATA(A_HWDATA), .HWSTRB(A_HWSTRB),
    .HWRITE(A_HWRITE), .HSIZE(A_HSIZE), .HBURST(A_HBURST),
    .HPROT(A_HPROT), .HTRANS(A_HTRANS), .HMASTLOCK(A_HMASTLOCK));
  wallypipelinedcore #(P) core_b(.clk, .reset,
    .MTimerInt, .MExtInt, .SExtInt, .MSwInt, .MTIME_CLINT, .ExternalStall,
    .HRDATA(B_HRDATA), .HREADY(B_HREADY), .HRESP(B_HRESP),
    .HCLK(B_HCLK), .HRESETn(B_HRESETn),
    .HADDR(B_HADDR), .HWDATA(B_HWDATA), .HWSTRB(B_HWSTRB),
    .HWRITE(B_HWRITE), .HSIZE(B_HSIZE), .HBURST(B_HBURST),
    .HPROT(B_HPROT), .HTRANS(B_HTRANS), .HMASTLOCK(B_HMASTLOCK));
  ahb_lockstep_guard #(.ADDR_WIDTH(P.PA_BITS), .DATA_WIDTH(P.AHBW),
    .STRB_WIDTH(P.XLEN/8), .SEQ_WIDTH(32), .ENABLE_INCR8(1)) lockstep_guard (
    .HCLK, .HRESETn,
    .A_HADDR, .A_HWDATA, .A_HWSTRB, .A_HWRITE, .A_HSIZE, .A_HBURST,
    .A_HPROT, .A_HTRANS, .A_HMASTLOCK, .A_HRDATA, .A_HREADY, .A_HRESP,
    .B_HADDR, .B_HWDATA, .B_HWSTRB, .B_HWRITE, .B_HSIZE, .B_HBURST,
    .B_HPROT, .B_HTRANS, .B_HMASTLOCK, .B_HRDATA, .B_HREADY, .B_HRESP,
    .M_HADDR(HADDR), .M_HWDATA(HWDATA), .M_HWSTRB(HWSTRB), .M_HWRITE(HWRITE),
    .M_HSIZE(HSIZE), .M_HBURST(HBURST), .M_HPROT(HPROT), .M_HTRANS(HTRANS),
    .M_HMASTLOCK(HMASTLOCK), .M_HRDATA(HRDATA), .M_HREADY(HREADY), .M_HRESP(HRESP),
    .A_pending_valid, .B_pending_valid, .A_req_valid, .B_req_valid,
    .pair_valid, .pair_ready, .match_valid, .match_ready, .policy_reject,
    .address_phase, .data_phase, .response_pending,
    .A_complete, .B_complete, .A_rsp_capture, .B_rsp_capture,
    .fault_valid, .compare_fault_reason, .gate_fault, .owner_seq,
    .authorized_dispatch, .down_accept, .down_complete,
    .pairing_wait_cycles, .a_peer_wait_cycles, .b_peer_wait_cycles,
    .pair_backpressure_cycles, .paired_requests);

  // Passive observation only: monitor the shared guard's downstream bus.
  if (P.BUS_SUPPORTED) begin : monitorgen
    ahb_monitor #(
      .ADDR_WIDTH(P.PA_BITS), .DATA_WIDTH(P.AHBW), .STRB_WIDTH(P.XLEN/8)
    ) monitor (
      .HCLK, .HRESETn, .HADDR, .HWDATA, .HWSTRB, .HWRITE,
      .HSIZE, .HBURST, .HPROT, .HTRANS, .HMASTLOCK,
      .HRDATA, .HREADY, .HRESP
    );
  end

  // instantiate uncore if a bus interface exists
  if (P.BUS_SUPPORTED) begin : uncoregen // Hack to work around Verilator bug https://github.com/verilator/verilator/issues/4769
    uncore #(P) uncore(.HCLK, .HRESETn, .TIMECLK,
      .HADDR, .HWDATA, .HWSTRB, .HWRITE, .HSIZE, .HBURST, .HPROT, .HTRANS, .HMASTLOCK, .HRDATAEXT,
      .HREADYEXT, .HRESPEXT, .HRDATA, .HREADY, .HRESP, .HSELEXT,
      .MTimerInt, .MSwInt, .MExtInt, .SExtInt, .GPIOIN, .GPIOOUT, .GPIOEN, .UARTSin,
      .UARTSout, .MTIME_CLINT, .SPIIn, .SPIOut, .SPICS, .SPICLK, .SDCIn, .SDCCmd, .SDCCS, .SDCCLK, .PWMGPIO);
  end else begin
    assign {HRDATA, HREADY, HRESP, HSELEXT, MTimerInt, MSwInt, MExtInt, SExtInt,
            MTIME_CLINT, GPIOOUT, GPIOEN, UARTSout, SPIOut, SPICS, SPICLK, SDCCmd, SDCCS, SDCCLK, PWMGPIO} = '0;
  end


endmodule
