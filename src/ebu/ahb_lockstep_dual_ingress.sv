// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Step 3C: two unchanged one-slot ingresses and one atomic request join.
// Independent response inputs are a future integration boundary, NOT a fork.
// The response producer must flush with this common reset (no epoch tags).
module ahb_lockstep_dual_ingress #(
  parameter integer ADDR_WIDTH = 56,
  parameter integer DATA_WIDTH = 64,
  parameter integer STRB_WIDTH = DATA_WIDTH / 8,
  parameter integer SEQ_WIDTH = 32
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
  input logic A_rsp_valid,
  output logic A_rsp_ready,
  input logic [DATA_WIDTH-1:0] A_rsp_rdata,
  input logic A_rsp_resp,
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
  input logic B_rsp_valid,
  output logic B_rsp_ready,
  input logic [DATA_WIDTH-1:0] B_rsp_rdata,
  input logic B_rsp_resp,
  output logic pair_valid,
  input logic pair_ready,
  output logic [SEQ_WIDTH-1:0] pair_seq,
  output logic [SEQ_WIDTH-1:0] pair_a_seq,
  output logic [ADDR_WIDTH-1:0] pair_a_addr,
  output logic pair_a_write,
  output logic [2:0] pair_a_size,
  output logic [2:0] pair_a_burst,
  output logic [3:0] pair_a_prot,
  output logic [1:0] pair_a_trans,
  output logic pair_a_lock,
  output logic [DATA_WIDTH-1:0] pair_a_wdata,
  output logic [STRB_WIDTH-1:0] pair_a_wstrb,
  output logic [SEQ_WIDTH-1:0] pair_b_seq,
  output logic [ADDR_WIDTH-1:0] pair_b_addr,
  output logic pair_b_write,
  output logic [2:0] pair_b_size,
  output logic [2:0] pair_b_burst,
  output logic [3:0] pair_b_prot,
  output logic [1:0] pair_b_trans,
  output logic pair_b_lock,
  output logic [DATA_WIDTH-1:0] pair_b_wdata,
  output logic [STRB_WIDTH-1:0] pair_b_wstrb,
  output logic [63:0] paired_requests,
  output logic [63:0] pairing_wait_cycles, a_peer_wait_cycles, b_peer_wait_cycles,
  output logic [63:0] pair_backpressure_cycles
);
  localparam integer REQ_WIDTH = SEQ_WIDTH + ADDR_WIDTH + 1 + 3 + 3 + 4 + 2 + 1 + DATA_WIDTH + STRB_WIDTH;
  logic a_req_ready, b_req_ready;
  logic [REQ_WIDTH-1:0] a_req_payload, b_req_payload;
  logic [REQ_WIDTH-1:0] pair_a_payload, pair_b_payload;
  assign {pair_a_seq,pair_a_addr,pair_a_write,pair_a_size,pair_a_burst,pair_a_prot,pair_a_trans,pair_a_lock,pair_a_wdata,pair_a_wstrb} = pair_a_payload;
  assign {pair_b_seq,pair_b_addr,pair_b_write,pair_b_size,pair_b_burst,pair_b_prot,pair_b_trans,pair_b_lock,pair_b_wdata,pair_b_wstrb} = pair_b_payload;
  logic [SEQ_WIDTH-1:0] a_req_seq;
  logic [ADDR_WIDTH-1:0] a_req_addr;
  logic a_req_write;
  logic [2:0] a_req_size;
  logic [2:0] a_req_burst;
  logic [3:0] a_req_prot;
  logic [1:0] a_req_trans;
  logic a_req_lock;
  logic [DATA_WIDTH-1:0] a_req_wdata;
  logic [STRB_WIDTH-1:0] a_req_wstrb;
  assign a_req_payload = {a_req_seq,a_req_addr,a_req_write,a_req_size,a_req_burst,a_req_prot,a_req_trans,a_req_lock,a_req_wdata,a_req_wstrb};
  ahb_lockstep_ingress #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
    .STRB_WIDTH(STRB_WIDTH), .SEQ_WIDTH(SEQ_WIDTH)) ingress_a (
    .HCLK, .HRESETn,
    .HADDR(A_HADDR),
    .HWDATA(A_HWDATA),
    .HWSTRB(A_HWSTRB),
    .HWRITE(A_HWRITE),
    .HMASTLOCK(A_HMASTLOCK),
    .HSIZE(A_HSIZE),
    .HBURST(A_HBURST),
    .HPROT(A_HPROT),
    .HTRANS(A_HTRANS),
    .HRDATA(A_HRDATA),
    .HREADY(A_HREADY),
    .HRESP(A_HRESP),
    .pending_valid(A_pending_valid), .req_valid(A_req_valid), .req_ready(a_req_ready),
    .req_seq(a_req_seq),
    .req_addr(a_req_addr),
    .req_write(a_req_write),
    .req_size(a_req_size),
    .req_burst(a_req_burst),
    .req_prot(a_req_prot),
    .req_trans(a_req_trans),
    .req_lock(a_req_lock),
    .req_wdata(a_req_wdata),
    .req_wstrb(a_req_wstrb),
    .rsp_valid(A_rsp_valid), .rsp_ready(A_rsp_ready),
    .rsp_rdata(A_rsp_rdata), .rsp_resp(A_rsp_resp)
  );
  logic [SEQ_WIDTH-1:0] b_req_seq;
  logic [ADDR_WIDTH-1:0] b_req_addr;
  logic b_req_write;
  logic [2:0] b_req_size;
  logic [2:0] b_req_burst;
  logic [3:0] b_req_prot;
  logic [1:0] b_req_trans;
  logic b_req_lock;
  logic [DATA_WIDTH-1:0] b_req_wdata;
  logic [STRB_WIDTH-1:0] b_req_wstrb;
  assign b_req_payload = {b_req_seq,b_req_addr,b_req_write,b_req_size,b_req_burst,b_req_prot,b_req_trans,b_req_lock,b_req_wdata,b_req_wstrb};
  ahb_lockstep_ingress #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
    .STRB_WIDTH(STRB_WIDTH), .SEQ_WIDTH(SEQ_WIDTH)) ingress_b (
    .HCLK, .HRESETn,
    .HADDR(B_HADDR),
    .HWDATA(B_HWDATA),
    .HWSTRB(B_HWSTRB),
    .HWRITE(B_HWRITE),
    .HMASTLOCK(B_HMASTLOCK),
    .HSIZE(B_HSIZE),
    .HBURST(B_HBURST),
    .HPROT(B_HPROT),
    .HTRANS(B_HTRANS),
    .HRDATA(B_HRDATA),
    .HREADY(B_HREADY),
    .HRESP(B_HRESP),
    .pending_valid(B_pending_valid), .req_valid(B_req_valid), .req_ready(b_req_ready),
    .req_seq(b_req_seq),
    .req_addr(b_req_addr),
    .req_write(b_req_write),
    .req_size(b_req_size),
    .req_burst(b_req_burst),
    .req_prot(b_req_prot),
    .req_trans(b_req_trans),
    .req_lock(b_req_lock),
    .req_wdata(b_req_wdata),
    .req_wstrb(b_req_wstrb),
    .rsp_valid(B_rsp_valid), .rsp_ready(B_rsp_ready),
    .rsp_rdata(B_rsp_rdata), .rsp_resp(B_rsp_resp)
  );
  ahb_lockstep_pair #(.REQ_WIDTH(REQ_WIDTH), .SEQ_WIDTH(SEQ_WIDTH)) alignment (
    .HCLK, .HRESETn, .a_req_valid(A_req_valid), .b_req_valid(B_req_valid),
    .a_req_ready, .b_req_ready, .a_req_payload, .b_req_payload,
    .pair_valid, .pair_ready, .pair_a_payload, .pair_b_payload, .pair_seq,
    .paired_requests, .pairing_wait_cycles, .a_peer_wait_cycles, .b_peer_wait_cycles,
    .pair_backpressure_cycles
  );
endmodule
