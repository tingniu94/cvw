// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// One-owner AHB-Lite master; optional validated INCR8 with BUSY gaps.
// Common reset must flush the slave too; accepted side effects cannot roll back.
module ahb_lockstep_output #(
  parameter integer ADDR_WIDTH=56, DATA_WIDTH=64,
  parameter integer STRB_WIDTH=DATA_WIDTH/8, SEQ_WIDTH=32,
  parameter bit ENABLE_INCR8=0
)(
  input logic HCLK,HRESETn,inhibit,
  input logic match_valid,
  output logic match_ready,
  input logic [SEQ_WIDTH-1:0] match_seq,
  input logic [ADDR_WIDTH-1:0] cmd_addr,
  input logic cmd_write,cmd_lock,
  input logic [2:0] cmd_size,cmd_burst,
  input logic [1:0] cmd_trans,
  input logic [3:0] cmd_prot,
  input logic [DATA_WIDTH-1:0] cmd_wdata,
  input logic [STRB_WIDTH-1:0] cmd_wstrb,
  output logic [ADDR_WIDTH-1:0] M_HADDR,
  output logic [DATA_WIDTH-1:0] M_HWDATA,
  output logic [STRB_WIDTH-1:0] M_HWSTRB,
  output logic M_HWRITE,M_HMASTLOCK,
  output logic [2:0] M_HSIZE,M_HBURST,
  output logic [3:0] M_HPROT,
  output logic [1:0] M_HTRANS,
  input logic [DATA_WIDTH-1:0] M_HRDATA,
  input logic M_HREADY,M_HRESP,
  output logic A_rsp_valid,B_rsp_valid,
  input logic A_rsp_ready,B_rsp_ready,
  output logic [DATA_WIDTH-1:0] rsp_rdata,
  output logic rsp_resp,
  input logic A_complete,B_complete,
  output logic [SEQ_WIDTH-1:0] owner_seq,
  // sticky: bit0 unsupported request, bit1 downstream error, bit2 release skew
  output logic [2:0] gate_fault,
  output logic authorized_dispatch,policy_reject,down_accept,down_complete,
  output logic address_phase,data_phase,response_pending
);
  typedef enum logic [2:0] {EMPTY,ADDRESS,DATA,RESPONSE,RELEASE,HALTED} state_t;
  state_t state;
  localparam integer MAX_SIZE=$clog2(DATA_WIDTH/8);
  logic supported,owner_write,error_seen,a_finished,b_finished;
  logic [ADDR_WIDTH-1:0] owner_addr;
  logic [DATA_WIDTH-1:0] owner_wdata;
  logic [STRB_WIDTH-1:0] owner_strb;
  logic [2:0] owner_size;
  logic [3:0] owner_prot;
  logic [2:0] owner_burst;
  logic [1:0] owner_trans;
  logic context_fault,context_active,busy_gap;
  logic [3:0] context_accepted;
  logic [ADDR_WIDTH-1:0] expected_addr;
  generate if(ENABLE_INCR8) begin : burst_mode
    ahb_lockstep_burst_context #(.ADDR_WIDTH(ADDR_WIDTH),.DATA_WIDTH(DATA_WIDTH),
      .ENABLE_INCR8(ENABLE_INCR8)) validator(
      .HCLK,.HRESETn,.cmd_valid(match_valid),
      .consumer_ready((state==EMPTY)&&(gate_fault==0)&&M_HREADY),
      .cmd_ready(match_ready),.authorized(authorized_dispatch),.rejected(policy_reject),
      .cmd_addr,.cmd_write,.cmd_lock,.cmd_size,.cmd_burst,.cmd_trans,.cmd_prot,
      .down_accept,.down_complete,.end_burst(1'b0),.compare_fault(inhibit),
      .fault(context_fault),.fault_reason(),.burst_active(context_active),
      .beat_pending(),.waiting_data(),.beat_index(),.accepted_count(context_accepted),
      .completed_count(),.expected_addr);
  end else begin : single_mode
    assign context_fault=0;
    assign context_active=0;
    assign context_accepted=0;
    assign expected_addr='0;
    assign match_ready=HRESETn&&(state==EMPTY)&&!inhibit&&(gate_fault==0)&&
      (M_HREADY||!supported);
    assign authorized_dispatch=match_valid&&match_ready&&supported;
    assign policy_reject=match_valid&&match_ready&&!supported;
  end endgenerate
  // Keep an unfinished fixed burst open, including fail-closed fault waits.
  // No ninth BUSY after address 8. Context still tracks its pending data.
  assign busy_gap=ENABLE_INCR8 && context_active && (context_accepted<8) && !address_phase;

  assign supported=(cmd_burst==3'b000)&&(cmd_trans==2'b10)&&!cmd_lock &&
    (cmd_size<=3'(MAX_SIZE)) &&
    ((cmd_addr & ((ADDR_WIDTH'(1)<<cmd_size)-ADDR_WIDTH'(1)))=='0);
  // Do not change even IDLE bus outputs across a pre-existing HREADY stall.
  // Unsupported metadata can be fault-received without changing the bus.
  assign address_phase=HRESETn&&(state==ADDRESS);
  assign data_phase=HRESETn&&(state==DATA);
  assign response_pending=HRESETn&&(state==RESPONSE);
  // After sampling ERROR cycle 1 (HRESP=1,HREADY=0), cancel the
  // remaining burst in cycle 2. Keep the old data owner/control intact;
  // error_seen stays set through response release/HALTED until common reset.
  // AHB-Lite permits this HTRANS change despite the preceding ERROR stall.
  assign M_HTRANS=!HRESETn ? 2'b00 : address_phase ? owner_trans :
                  error_seen ? 2'b00 : busy_gap ? 2'b01 : 2'b00;
  assign M_HADDR=busy_gap ? expected_addr : owner_addr;
  // This is the NEXT (IDLE) address direction during the old write data phase.
  assign M_HWRITE=ENABLE_INCR8 ? owner_write : address_phase&&owner_write;
  assign M_HSIZE=owner_size;
  assign M_HBURST=ENABLE_INCR8 ? owner_burst : 3'b000;
  assign M_HPROT=owner_prot;
  assign M_HMASTLOCK=1'b0;
  assign M_HWDATA=owner_wdata;
  assign M_HWSTRB=owner_write ? owner_strb : '0;
  assign down_accept=address_phase&&M_HREADY;
  assign down_complete=data_phase&&M_HREADY;
  // Neither consumer can consume alone. Ingress ready is state-based and
  // independent of valid, so this barrier creates no combinational ready loop.
  assign A_rsp_valid=response_pending&&A_rsp_ready&&B_rsp_ready;
  assign B_rsp_valid=A_rsp_valid;

  initial begin
    assert((DATA_WIDTH==32 || DATA_WIDTH==64) && STRB_WIDTH==DATA_WIDTH/8)
      else $fatal(1,"Unsupported output data/strobe width");
  end
  always_ff @(posedge HCLK or negedge HRESETn) begin
    if(!HRESETn) begin
      state<=EMPTY;owner_seq<='0;owner_addr<='0;owner_write<=0;
      owner_wdata<='0;owner_strb<='0;owner_size<='0;owner_prot<='0;
      owner_burst<=0;owner_trans<=2'b10;
      error_seen<=0;a_finished<=0;b_finished<=0;
      rsp_rdata<='0;rsp_resp<=0;gate_fault<=0;
    end else begin
      if(ENABLE_INCR8 && context_fault) gate_fault[0]<=1;
      case(state)
        EMPTY: if(match_valid&&match_ready) begin
          owner_seq<=match_seq;
          if(policy_reject) begin gate_fault[0]<=1;state<=HALTED;end
          else begin
            owner_addr<=cmd_addr;owner_write<=cmd_write;owner_size<=cmd_size;
            owner_prot<=cmd_prot;owner_wdata<=cmd_wdata;owner_strb<=cmd_wstrb;
            owner_burst<=cmd_burst;owner_trans<=cmd_trans;
            error_seen<=0;a_finished<=0;b_finished<=0;
            state<=ADDRESS;
          end
        end
        ADDRESS: if(M_HREADY) state<=DATA;
        DATA: begin
          if(M_HRESP) error_seen<=1;
          if(M_HREADY) begin
            rsp_rdata<=M_HRDATA;rsp_resp<=M_HRESP||error_seen;
            if(M_HRESP||error_seen) gate_fault[1]<=1;
            state<=RESPONSE;
          end
        end
        RESPONSE: if(A_rsp_ready&&B_rsp_ready) state<=RELEASE;
        RELEASE: begin
          if(A_complete) a_finished<=1;
          if(B_complete) b_finished<=1;
          if(A_complete!=B_complete) gate_fault[2]<=1;
          if((a_finished||A_complete)&&(b_finished||B_complete)) begin
            if(gate_fault!=0 || A_complete!=B_complete) state<=HALTED;
            else state<=EMPTY;
          end
        end
        HALTED: state<=HALTED;
        default: begin gate_fault[2]<=1;state<=HALTED;end
      endcase
    end
  end
endmodule
