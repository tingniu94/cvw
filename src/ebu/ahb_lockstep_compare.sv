// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Step 3D: consume saved paired requests into one registered result slot.
// MATCH is an internal request authorization, not an AHB completion/response.
// Fault is sticky until common reset; no response is manufactured here.
module ahb_lockstep_compare #(
  parameter integer ADDR_WIDTH=56,
  parameter integer DATA_WIDTH=64,
  parameter integer STRB_WIDTH=DATA_WIDTH/8,
  parameter integer SEQ_WIDTH=32
)(
  input logic HCLK, HRESETn,
  input logic pair_valid,
  output logic pair_ready,
  input logic [SEQ_WIDTH-1:0] pair_seq,
  input logic [SEQ_WIDTH-1:0] pair_a_seq,
  input logic [ADDR_WIDTH-1:0] pair_a_addr,
  input logic pair_a_write,
  input logic [2:0] pair_a_size,
  input logic [2:0] pair_a_burst,
  input logic [3:0] pair_a_prot,
  input logic [1:0] pair_a_trans,
  input logic pair_a_lock,
  input logic [DATA_WIDTH-1:0] pair_a_wdata,
  input logic [STRB_WIDTH-1:0] pair_a_wstrb,
  input logic [SEQ_WIDTH-1:0] pair_b_seq,
  input logic [ADDR_WIDTH-1:0] pair_b_addr,
  input logic pair_b_write,
  input logic [2:0] pair_b_size,
  input logic [2:0] pair_b_burst,
  input logic [3:0] pair_b_prot,
  input logic [1:0] pair_b_trans,
  input logic pair_b_lock,
  input logic [DATA_WIDTH-1:0] pair_b_wdata,
  input logic [STRB_WIDTH-1:0] pair_b_wstrb,
  output logic match_valid,
  input logic match_ready,
  output logic fault_valid,
  // 0 address,1 direction,2 size,3 burst,4 prot,5 trans,6 lock,
  // 7 write data,8 strobe,9 ordinal precondition,10 valid-beat precondition.
  output logic [10:0] fault_reason,
  output logic [SEQ_WIDTH-1:0] result_seq,
  output logic [SEQ_WIDTH-1:0] saved_a_seq,
  output logic [ADDR_WIDTH-1:0] saved_a_addr,
  output logic saved_a_write,
  output logic [2:0] saved_a_size,
  output logic [2:0] saved_a_burst,
  output logic [3:0] saved_a_prot,
  output logic [1:0] saved_a_trans,
  output logic saved_a_lock,
  output logic [DATA_WIDTH-1:0] saved_a_wdata,
  output logic [STRB_WIDTH-1:0] saved_a_wstrb,
  output logic [SEQ_WIDTH-1:0] saved_b_seq,
  output logic [ADDR_WIDTH-1:0] saved_b_addr,
  output logic saved_b_write,
  output logic [2:0] saved_b_size,
  output logic [2:0] saved_b_burst,
  output logic [3:0] saved_b_prot,
  output logic [1:0] saved_b_trans,
  output logic saved_b_lock,
  output logic [DATA_WIDTH-1:0] saved_b_wdata,
  output logic [STRB_WIDTH-1:0] saved_b_wstrb
);
  typedef enum logic [1:0] {EMPTY, MATCH_PENDING, FAULT} state_t;
  state_t state;
  logic [10:0] reasons;
  assign pair_ready=HRESETn && (state==EMPTY);
  assign match_valid=HRESETn && (state==MATCH_PENDING);
  assign fault_valid=HRESETn && (state==FAULT);

  // All operands are the Step 3C saved-payload port, not live AHB pins.
  always_comb begin
    reasons='0;
    reasons[9]=(pair_a_seq!=pair_b_seq) || (pair_a_seq!=pair_seq);
    reasons[10]=!pair_a_trans[1] || !pair_b_trans[1];
    // Only qualified ordinals/valid beats undergo payload comparison.
    if (reasons[10:9]==2'b00) begin
      reasons[0]=(pair_a_addr!=pair_b_addr);
      reasons[1]=(pair_a_write!=pair_b_write);
      reasons[2]=(pair_a_size!=pair_b_size);
      reasons[3]=(pair_a_burst!=pair_b_burst);
      reasons[4]=(pair_a_prot!=pair_b_prot);
      reasons[5]=(pair_a_trans!=pair_b_trans);
      reasons[6]=(pair_a_lock!=pair_b_lock);
      // Read data/strobe are not request semantics; direction mismatch
      // faults on bit1 without comparing a Read's meaningless write lanes.
      if (pair_a_write && pair_b_write) begin
        reasons[7]=(pair_a_wdata!=pair_b_wdata);
        reasons[8]=(pair_a_wstrb!=pair_b_wstrb);
      end
    end
  end

  always_ff @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) begin
      state<=EMPTY;result_seq<='0;fault_reason<='0;
      saved_a_seq<='0;
      saved_a_addr<='0;
      saved_a_write<='0;
      saved_a_size<='0;
      saved_a_burst<='0;
      saved_a_prot<='0;
      saved_a_trans<='0;
      saved_a_lock<='0;
      saved_a_wdata<='0;
      saved_a_wstrb<='0;
      saved_b_seq<='0;
      saved_b_addr<='0;
      saved_b_write<='0;
      saved_b_size<='0;
      saved_b_burst<='0;
      saved_b_prot<='0;
      saved_b_trans<='0;
      saved_b_lock<='0;
      saved_b_wdata<='0;
      saved_b_wstrb<='0;
    end else begin
      case (state)
        EMPTY: if (pair_valid) begin
          result_seq<=pair_seq;
          fault_reason<=reasons;
          saved_a_seq<=pair_a_seq;
          saved_a_addr<=pair_a_addr;
          saved_a_write<=pair_a_write;
          saved_a_size<=pair_a_size;
          saved_a_burst<=pair_a_burst;
          saved_a_prot<=pair_a_prot;
          saved_a_trans<=pair_a_trans;
          saved_a_lock<=pair_a_lock;
          saved_a_wdata<=pair_a_wdata;
          saved_a_wstrb<=pair_a_wstrb;
          saved_b_seq<=pair_b_seq;
          saved_b_addr<=pair_b_addr;
          saved_b_write<=pair_b_write;
          saved_b_size<=pair_b_size;
          saved_b_burst<=pair_b_burst;
          saved_b_prot<=pair_b_prot;
          saved_b_trans<=pair_b_trans;
          saved_b_lock<=pair_b_lock;
          saved_b_wdata<=pair_b_wdata;
          saved_b_wstrb<=pair_b_wstrb;
          // In four-state simulation an unknown equality cannot grant MATCH.
          // This suite validates two-state behavior; no X/Z coverage claimed.
          if (reasons=='0) state<=MATCH_PENDING;
          else state<=FAULT;
        end
        MATCH_PENDING: if (match_ready) state<=EMPTY;
        FAULT: state<=FAULT;
        default: state<=FAULT;
      endcase
    end
  end
endmodule
