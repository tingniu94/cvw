// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// F1 standalone validator. cmd_* MUST be a registered MATCH saved payload.
// This block does not drive AHB or manufacture responses. One issued beat at a time.
module ahb_lockstep_burst_context #(
  parameter integer ADDR_WIDTH=56, DATA_WIDTH=64,
  parameter bit ENABLE_INCR8=0
)(
  input logic HCLK,HRESETn,
  input logic cmd_valid,consumer_ready,
  output logic cmd_ready,authorized,rejected,
  input logic [ADDR_WIDTH-1:0] cmd_addr,
  input logic cmd_write,cmd_lock,
  input logic [2:0] cmd_size,cmd_burst,
  input logic [1:0] cmd_trans,
  input logic [3:0] cmd_prot,
  // Explicit scheduler events, NOT unqualified HREADY or live IDLE/BUSY.
  input logic down_accept,down_complete,end_burst,compare_fault,
  output logic fault,
  // bit0 shape/policy,1 alignment,2 boundary,3 sequence,4 address,
  // bit5 invariant control,6 premature end,7 comparator fault,8 event ownership
  output logic [8:0] fault_reason,
  output logic burst_active,beat_pending,waiting_data,
  output logic [2:0] beat_index,
  output logic [3:0] accepted_count,completed_count,
  output logic [ADDR_WIDTH-1:0] expected_addr
);
  typedef enum logic [1:0] {READY,ADDRESS,DATA} phase_t;
  phase_t phase;
  logic [ADDR_WIDTH-1:0] step_bytes;
  logic saved_write;
  logic [2:0] saved_size;
  logic [3:0] saved_prot;
  logic [8:0] reasons,events;
  logic [ADDR_WIDTH:0] last_addr;
  localparam integer MAX_SIZE=$clog2(DATA_WIDTH/8);
  initial begin
    assert(ADDR_WIDTH>=11 && (DATA_WIDTH==32 || DATA_WIDTH==64))
      else $fatal(1,"Unsupported F1 width");
  end
  always_comb begin
    reasons='0;
    last_addr={1'b0,cmd_addr}+(({{ADDR_WIDTH{1'b0}},1'b1}<<cmd_size)*7);
    reasons[0]=cmd_lock || (cmd_size>3'(MAX_SIZE)) ||
      !((cmd_burst==0)||(ENABLE_INCR8 && cmd_burst==5));
    reasons[1]=(cmd_addr & ((ADDR_WIDTH'(1)<<cmd_size)-ADDR_WIDTH'(1)))!=0;
    if(burst_active) begin
      reasons[3]=(cmd_trans!=2'b11);
      reasons[4]=(cmd_addr!=expected_addr);
      reasons[5]=(cmd_burst!=5)||(cmd_size!=saved_size)||
                 (cmd_write!=saved_write)||(cmd_prot!=saved_prot);
    end else begin
      reasons[3]=(cmd_trans!=2'b10);
      if(cmd_burst==5)
        reasons[2]=(last_addr[ADDR_WIDTH:10]!={1'b0,cmd_addr[ADDR_WIDTH-1:10]});
    end
    events='0;
    events[6]=end_burst && burst_active &&
      !((phase==DATA)&&down_complete&&(accepted_count==8));
    events[7]=compare_fault;
    events[8]=(down_accept && phase!=ADDRESS)||(down_complete && phase!=DATA);
  end
  assign cmd_ready=HRESETn && !fault && (phase==READY) && consumer_ready && (events==0);
  assign authorized=cmd_valid && cmd_ready && (reasons==0);
  assign rejected=cmd_valid && cmd_ready && (reasons!=0);
  assign beat_pending=(phase!=READY);
  assign waiting_data=(phase==DATA);
  // Current owner in DATA; otherwise next address index. Final pending = 7, not 0.
  assign beat_index=burst_active ?
    ((phase==DATA) ? 3'(accepted_count-4'd1) : 3'(accepted_count)) : 3'b000;
  always_ff @(posedge HCLK or negedge HRESETn) begin
    if(!HRESETn) begin
      phase<=READY;fault<=0;fault_reason<=0;burst_active<=0;
      accepted_count<=0;completed_count<=0;expected_addr<=0;step_bytes<=0;
      saved_write<=0;saved_size<=0;saved_prot<=0;
    end else begin
      // Completion/acceptance of already authorized work remains accounted for
      // even if a comparator fault arrives; fault never authorizes new work.
      if(down_accept && phase==ADDRESS) begin
        phase<=DATA;accepted_count<=accepted_count+1'b1;
        if(burst_active) expected_addr<=expected_addr+step_bytes;
      end
      if(down_complete && phase==DATA) begin
        phase<=READY;completed_count<=completed_count+1'b1;
        if(burst_active && accepted_count==8) burst_active<=0;
      end
      if(!fault) begin
        if(events!=0) begin fault<=1;fault_reason<=events;end
        else if(rejected) begin fault<=1;fault_reason<=reasons;end
        else if(authorized) begin
          phase<=ADDRESS;
          if(!burst_active) begin
            burst_active<=(cmd_burst==5);
            accepted_count<=0;completed_count<=0;
            expected_addr<=cmd_addr;
            step_bytes<=ADDR_WIDTH'(1)<<cmd_size;
            saved_write<=cmd_write;saved_size<=cmd_size;saved_prot<=cmd_prot;
          end
        end
      end
    end
  end
endmodule
