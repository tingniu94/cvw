///////////////////////////////////////////
// Passive A-only AHB monitor. All ports are inputs; no bus feedback.
// Records completed beats, pairing saved address/control with data phase.
///////////////////////////////////////////
module ahb_monitor #(
  parameter integer ADDR_WIDTH = 56,
  parameter integer DATA_WIDTH = 64,
  parameter integer STRB_WIDTH = DATA_WIDTH / 8
)(
  input logic HCLK, HRESETn,
  input logic [ADDR_WIDTH-1:0] HADDR,
  input logic [DATA_WIDTH-1:0] HWDATA, HRDATA,
  input logic [STRB_WIDTH-1:0] HWSTRB,
  input logic HWRITE,
  input logic [2:0] HSIZE, HBURST,
  input logic [3:0] HPROT,
  input logic [1:0] HTRANS,
  input logic HMASTLOCK, HREADY, HRESP
);
`ifndef SYNTHESIS
  logic pending;
  logic [ADDR_WIDTH-1:0] addr_q;
  logic write_q, lock_q;
  logic [2:0] size_q, burst_q;
  logic [3:0] prot_q;
  logic [1:0] trans_q;
  longint unsigned completed, cycle_count, address_cycle, wait_cycles;
  integer log_enable;
  longint unsigned log_limit;

  // Default: at most 20 completed transactions. 0 limit means unlimited.
  // +AHB_MONITOR=0 silences logs without changing observation or the bus.
  initial begin
    log_enable = 1;
    log_limit = 20;
    if ($value$plusargs("AHB_MONITOR=%d", log_enable)) begin end
    if ($value$plusargs("AHB_MONITOR_LIMIT=%d", log_limit)) begin end
  end

  always @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) begin
      pending <= 1'b0;
      addr_q <= '0;
      write_q <= 1'b0;
      lock_q <= 1'b0;
      size_q <= '0;
      burst_q <= '0;
      prot_q <= '0;
      trans_q <= '0;
      completed <= 0;
      cycle_count <= 0;
      address_cycle <= 0;
      wait_cycles <= 0;
    end else begin
      cycle_count <= cycle_count + 1;
      if (HREADY) begin
        // Complete the OLD data phase before saving the NEXT address phase.
        // IDLE/BUSY do not create a transaction. Stalls retain all metadata.
        if (pending) begin
          completed <= completed + 1;
          if (log_enable != 0 && (log_limit == 0 || completed < log_limit)) begin
            if (write_q)
              $display("[AHB_MON] beat=%0d addr_cycle=%0d done_cycle=%0d waits=%0d write=1 addr=%h trans=%b size=%0d burst=%0d prot=%h lock=%b wdata=%h strb=%h resp=%b",
                completed, address_cycle, cycle_count, wait_cycles, addr_q,
                trans_q, size_q, burst_q, prot_q, lock_q, HWDATA, HWSTRB, HRESP);
            else
              $display("[AHB_MON] beat=%0d addr_cycle=%0d done_cycle=%0d waits=%0d write=0 addr=%h trans=%b size=%0d burst=%0d prot=%h lock=%b rdata=%h resp=%b",
                completed, address_cycle, cycle_count, wait_cycles, addr_q,
                trans_q, size_q, burst_q, prot_q, lock_q, HRDATA, HRESP);
          end
        end
        pending <= HTRANS[1];
        wait_cycles <= 0;
        if (HTRANS[1]) begin
          addr_q <= HADDR;
          write_q <= HWRITE;
          size_q <= HSIZE;
          burst_q <= HBURST;
          prot_q <= HPROT;
          trans_q <= HTRANS;
          lock_q <= HMASTLOCK;
          address_cycle <= cycle_count;
        end
      end else if (pending) wait_cycles <= wait_cycles + 1;
    end
  end
`endif
endmodule
