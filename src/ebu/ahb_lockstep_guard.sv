// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Synthetic/standalone Step 3E top, not connected to the SoC.
module ahb_lockstep_guard #(
  parameter integer ADDR_WIDTH=56,DATA_WIDTH=64,
  parameter integer STRB_WIDTH=DATA_WIDTH/8,SEQ_WIDTH=32
)(
  input logic HCLK, HRESETn,
  input logic [ADDR_WIDTH-1:0] A_HADDR,
  input logic [DATA_WIDTH-1:0] A_HWDATA,
  input logic [STRB_WIDTH-1:0] A_HWSTRB,
  input logic A_HWRITE, A_HMASTLOCK,
  input logic [2:0] A_HSIZE, A_HBURST,
  input logic [3:0] A_HPROT,
  input logic [1:0] A_HTRANS,
  output logic [DATA_WIDTH-1:0] A_HRDATA,
  output logic A_HREADY, A_HRESP,
  output logic A_pending_valid, A_req_valid,
  input logic [ADDR_WIDTH-1:0] B_HADDR,
  input logic [DATA_WIDTH-1:0] B_HWDATA,
  input logic [STRB_WIDTH-1:0] B_HWSTRB,
  input logic B_HWRITE, B_HMASTLOCK,
  input logic [2:0] B_HSIZE, B_HBURST,
  input logic [3:0] B_HPROT,
  input logic [1:0] B_HTRANS,
  output logic [DATA_WIDTH-1:0] B_HRDATA,
  output logic B_HREADY, B_HRESP,
  output logic B_pending_valid, B_req_valid,
  output logic [ADDR_WIDTH-1:0] M_HADDR,
  output logic [DATA_WIDTH-1:0] M_HWDATA,
  output logic [STRB_WIDTH-1:0] M_HWSTRB,
  output logic M_HWRITE,M_HMASTLOCK,
  output logic [2:0] M_HSIZE,M_HBURST,
  output logic [3:0] M_HPROT,
  output logic [1:0] M_HTRANS,
  input logic [DATA_WIDTH-1:0] M_HRDATA,
  input logic M_HREADY,M_HRESP,
  output logic fault_valid,
  output logic [10:0] compare_fault_reason,
  output logic [2:0] gate_fault,
  output logic [SEQ_WIDTH-1:0] owner_seq,
  output logic pair_valid,pair_ready,match_valid,match_ready,
  output logic authorized_dispatch,policy_reject,down_accept,down_complete,
  output logic address_phase,data_phase,response_pending,
  output logic A_complete,B_complete,A_rsp_capture,B_rsp_capture,
  output logic [63:0] pairing_wait_cycles,a_peer_wait_cycles,b_peer_wait_cycles,
  output logic [63:0] pair_backpressure_cycles,paired_requests
);
  typedef struct packed {
    logic [SEQ_WIDTH-1:0] seq;
    logic [ADDR_WIDTH-1:0] addr;
    logic write;
    logic [2:0] size,burst;
    logic [3:0] prot;
    logic [1:0] trans;
    logic lock;
    logic [DATA_WIDTH-1:0] wdata;
    logic [STRB_WIDTH-1:0] wstrb;
  } request_t;
  request_t paired_a,paired_b,saved_a,saved_b;
  logic [SEQ_WIDTH-1:0] pair_seq,result_seq;
  logic raw_pair_ready,cmp_fault;
  logic A_rsp_valid,B_rsp_valid,A_rsp_ready,B_rsp_ready,rsp_resp;
  logic [DATA_WIDTH-1:0] rsp_rdata;
  assign fault_valid=cmp_fault||(gate_fault!=0);
  assign pair_ready=raw_pair_ready&&!fault_valid;
  assign A_complete=HRESETn&&A_pending_valid&&A_HREADY;
  assign B_complete=HRESETn&&B_pending_valid&&B_HREADY;
  assign A_rsp_capture=A_rsp_valid&&A_rsp_ready;
  assign B_rsp_capture=B_rsp_valid&&B_rsp_ready;
  ahb_lockstep_dual_ingress #(.ADDR_WIDTH(ADDR_WIDTH),.DATA_WIDTH(DATA_WIDTH),
    .STRB_WIDTH(STRB_WIDTH),.SEQ_WIDTH(SEQ_WIDTH)) ingress_pair(
    .HCLK,.HRESETn,
    .A_HADDR,
    .A_HWDATA,
    .A_HWSTRB,
    .A_HWRITE,
    .A_HMASTLOCK,
    .A_HSIZE,
    .A_HBURST,
    .A_HPROT,
    .A_HTRANS,
    .A_HRDATA,
    .A_HREADY,
    .A_HRESP,
    .A_pending_valid,
    .A_req_valid,
    .A_rsp_valid,
    .A_rsp_ready,
    .A_rsp_rdata(rsp_rdata),.A_rsp_resp(rsp_resp),
    .B_HADDR,
    .B_HWDATA,
    .B_HWSTRB,
    .B_HWRITE,
    .B_HMASTLOCK,
    .B_HSIZE,
    .B_HBURST,
    .B_HPROT,
    .B_HTRANS,
    .B_HRDATA,
    .B_HREADY,
    .B_HRESP,
    .B_pending_valid,
    .B_req_valid,
    .B_rsp_valid,
    .B_rsp_ready,
    .B_rsp_rdata(rsp_rdata),.B_rsp_resp(rsp_resp),
    .pair_a_seq(paired_a.seq),
    .pair_a_addr(paired_a.addr),
    .pair_a_write(paired_a.write),
    .pair_a_size(paired_a.size),
    .pair_a_burst(paired_a.burst),
    .pair_a_prot(paired_a.prot),
    .pair_a_trans(paired_a.trans),
    .pair_a_lock(paired_a.lock),
    .pair_a_wdata(paired_a.wdata),
    .pair_a_wstrb(paired_a.wstrb),
    .pair_b_seq(paired_b.seq),
    .pair_b_addr(paired_b.addr),
    .pair_b_write(paired_b.write),
    .pair_b_size(paired_b.size),
    .pair_b_burst(paired_b.burst),
    .pair_b_prot(paired_b.prot),
    .pair_b_trans(paired_b.trans),
    .pair_b_lock(paired_b.lock),
    .pair_b_wdata(paired_b.wdata),
    .pair_b_wstrb(paired_b.wstrb),
    .pair_valid,.pair_ready,.pair_seq,.paired_requests,.pairing_wait_cycles,
    .a_peer_wait_cycles,.b_peer_wait_cycles,.pair_backpressure_cycles
  );
  ahb_lockstep_compare #(.ADDR_WIDTH(ADDR_WIDTH),.DATA_WIDTH(DATA_WIDTH),
    .STRB_WIDTH(STRB_WIDTH),.SEQ_WIDTH(SEQ_WIDTH)) comparator(
    .HCLK,.HRESETn,.pair_valid(pair_valid&&!fault_valid),
    .pair_ready(raw_pair_ready),.pair_seq,
    .pair_a_seq(paired_a.seq),
    .pair_a_addr(paired_a.addr),
    .pair_a_write(paired_a.write),
    .pair_a_size(paired_a.size),
    .pair_a_burst(paired_a.burst),
    .pair_a_prot(paired_a.prot),
    .pair_a_trans(paired_a.trans),
    .pair_a_lock(paired_a.lock),
    .pair_a_wdata(paired_a.wdata),
    .pair_a_wstrb(paired_a.wstrb),
    .pair_b_seq(paired_b.seq),
    .pair_b_addr(paired_b.addr),
    .pair_b_write(paired_b.write),
    .pair_b_size(paired_b.size),
    .pair_b_burst(paired_b.burst),
    .pair_b_prot(paired_b.prot),
    .pair_b_trans(paired_b.trans),
    .pair_b_lock(paired_b.lock),
    .pair_b_wdata(paired_b.wdata),
    .pair_b_wstrb(paired_b.wstrb),
    .saved_a_seq(saved_a.seq),
    .saved_a_addr(saved_a.addr),
    .saved_a_write(saved_a.write),
    .saved_a_size(saved_a.size),
    .saved_a_burst(saved_a.burst),
    .saved_a_prot(saved_a.prot),
    .saved_a_trans(saved_a.trans),
    .saved_a_lock(saved_a.lock),
    .saved_a_wdata(saved_a.wdata),
    .saved_a_wstrb(saved_a.wstrb),
    .saved_b_seq(saved_b.seq),
    .saved_b_addr(saved_b.addr),
    .saved_b_write(saved_b.write),
    .saved_b_size(saved_b.size),
    .saved_b_burst(saved_b.burst),
    .saved_b_prot(saved_b.prot),
    .saved_b_trans(saved_b.trans),
    .saved_b_lock(saved_b.lock),
    .saved_b_wdata(saved_b.wdata),
    .saved_b_wstrb(saved_b.wstrb),
    .match_valid,.match_ready,.fault_valid(cmp_fault),
    .fault_reason(compare_fault_reason),.result_seq
  );
  ahb_lockstep_output #(.ADDR_WIDTH(ADDR_WIDTH),.DATA_WIDTH(DATA_WIDTH),
    .STRB_WIDTH(STRB_WIDTH),.SEQ_WIDTH(SEQ_WIDTH)) output_backend(
    .HCLK,.HRESETn,.inhibit(cmp_fault),.match_valid,.match_ready,.match_seq(result_seq),
    .cmd_addr(saved_a.addr),
    .cmd_write(saved_a.write),
    .cmd_lock(saved_a.lock),
    .cmd_size(saved_a.size),
    .cmd_burst(saved_a.burst),
    .cmd_trans(saved_a.trans),
    .cmd_prot(saved_a.prot),
    .cmd_wdata(saved_a.wdata),
    .cmd_wstrb(saved_a.wstrb),
    .M_HADDR,.M_HWDATA,.M_HWSTRB,.M_HWRITE,.M_HMASTLOCK,
    .M_HSIZE,.M_HBURST,.M_HPROT,.M_HTRANS,.M_HRDATA,.M_HREADY,.M_HRESP,
    .A_rsp_valid,.B_rsp_valid,.A_rsp_ready,.B_rsp_ready,.rsp_rdata,.rsp_resp,
    .A_complete,.B_complete,.owner_seq,.gate_fault,
    .authorized_dispatch,.policy_reject,.down_accept,.down_complete,
    .address_phase,.data_phase,.response_pending
  );
endmodule
