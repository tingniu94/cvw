// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Synthetic AHB agents and an independent acceptance/pair/completion ledger.
module compare_ingress_tb;
  localparam integer SEQ_WIDTH=3; // exercise ordinal wrap in the repeated stream
  logic HCLK=0, HRESETn=0;
  always #5 HCLK=~HCLK;
  typedef struct packed {
    logic [SEQ_WIDTH-1:0] seq;
    logic [55:0] addr;
    logic wr;
    logic [2:0] size, burst;
    logic [3:0] prot;
    logic [1:0] trans;
    logic lock;
    logic [63:0] wdata;
    logic [7:0] strb;
  } request_t;
  logic [55:0] addr[2];
  logic [63:0] wdata[2], rdata[2], rsp_data[2];
  logic [7:0] strb[2];
  logic wr[2], lock[2], ready[2], resp[2], pending[2], req_valid[2];
  logic rsp_valid[2], rsp_ready[2], rsp_resp[2];
  logic [2:0] size[2], burst[2];
  logic [3:0] prot[2];
  logic [1:0] trans[2];
  request_t paired[2];
  logic pair_valid, pair_ready;
  logic [SEQ_WIDTH-1:0] pair_seq;
  logic [63:0] paired_requests, pairing_wait_cycles, a_peer_wait_cycles, b_peer_wait_cycles;
  logic [63:0] pair_backpressure_cycles;
  ahb_lockstep_dual_ingress #(.SEQ_WIDTH(SEQ_WIDTH)) dut(
    .HCLK, .HRESETn,
    .A_HADDR(addr[0]),
    .A_HWDATA(wdata[0]),
    .A_HWSTRB(strb[0]),
    .A_HWRITE(wr[0]),
    .A_HMASTLOCK(lock[0]),
    .A_HSIZE(size[0]),
    .A_HBURST(burst[0]),
    .A_HPROT(prot[0]),
    .A_HTRANS(trans[0]),
    .A_HRDATA(rdata[0]),
    .A_HREADY(ready[0]),
    .A_HRESP(resp[0]),
    .A_pending_valid(pending[0]),
    .A_req_valid(req_valid[0]),
    .A_rsp_valid(rsp_valid[0]),
    .A_rsp_ready(rsp_ready[0]),
    .A_rsp_rdata(rsp_data[0]),
    .A_rsp_resp(rsp_resp[0]),
    .B_HADDR(addr[1]),
    .B_HWDATA(wdata[1]),
    .B_HWSTRB(strb[1]),
    .B_HWRITE(wr[1]),
    .B_HMASTLOCK(lock[1]),
    .B_HSIZE(size[1]),
    .B_HBURST(burst[1]),
    .B_HPROT(prot[1]),
    .B_HTRANS(trans[1]),
    .B_HRDATA(rdata[1]),
    .B_HREADY(ready[1]),
    .B_HRESP(resp[1]),
    .B_pending_valid(pending[1]),
    .B_req_valid(req_valid[1]),
    .B_rsp_valid(rsp_valid[1]),
    .B_rsp_ready(rsp_ready[1]),
    .B_rsp_rdata(rsp_data[1]),
    .B_rsp_resp(rsp_resp[1]),
    .pair_a_seq(paired[0].seq),
    .pair_a_addr(paired[0].addr),
    .pair_a_write(paired[0].wr),
    .pair_a_size(paired[0].size),
    .pair_a_burst(paired[0].burst),
    .pair_a_prot(paired[0].prot),
    .pair_a_trans(paired[0].trans),
    .pair_a_lock(paired[0].lock),
    .pair_a_wdata(paired[0].wdata),
    .pair_a_wstrb(paired[0].strb),
    .pair_b_seq(paired[1].seq),
    .pair_b_addr(paired[1].addr),
    .pair_b_write(paired[1].wr),
    .pair_b_size(paired[1].size),
    .pair_b_burst(paired[1].burst),
    .pair_b_prot(paired[1].prot),
    .pair_b_trans(paired[1].trans),
    .pair_b_lock(paired[1].lock),
    .pair_b_wdata(paired[1].wdata),
    .pair_b_wstrb(paired[1].strb),
    .pair_valid, .pair_ready, .pair_seq, .paired_requests,
    .pairing_wait_cycles, .a_peer_wait_cycles, .b_peer_wait_cycles,
    .pair_backpressure_cycles
  );

  request_t saved_result[2], accepted_payload[2];
  logic match_valid,match_ready=0,fault_valid;
  logic [10:0] fault_reason;
  logic [SEQ_WIDTH-1:0] result_seq;
  ahb_lockstep_compare #(.SEQ_WIDTH(SEQ_WIDTH)) comparator(
    .HCLK,.HRESETn,.pair_valid,.pair_ready,.pair_seq,
    .pair_a_seq(paired[0].seq),
    .pair_a_addr(paired[0].addr),
    .pair_a_write(paired[0].wr),
    .pair_a_size(paired[0].size),
    .pair_a_burst(paired[0].burst),
    .pair_a_prot(paired[0].prot),
    .pair_a_trans(paired[0].trans),
    .pair_a_lock(paired[0].lock),
    .pair_a_wdata(paired[0].wdata),
    .pair_a_wstrb(paired[0].strb),
    .pair_b_seq(paired[1].seq),
    .pair_b_addr(paired[1].addr),
    .pair_b_write(paired[1].wr),
    .pair_b_size(paired[1].size),
    .pair_b_burst(paired[1].burst),
    .pair_b_prot(paired[1].prot),
    .pair_b_trans(paired[1].trans),
    .pair_b_lock(paired[1].lock),
    .pair_b_wdata(paired[1].wdata),
    .pair_b_wstrb(paired[1].strb),
    .saved_a_seq(saved_result[0].seq),
    .saved_a_addr(saved_result[0].addr),
    .saved_a_write(saved_result[0].wr),
    .saved_a_size(saved_result[0].size),
    .saved_a_burst(saved_result[0].burst),
    .saved_a_prot(saved_result[0].prot),
    .saved_a_trans(saved_result[0].trans),
    .saved_a_lock(saved_result[0].lock),
    .saved_a_wdata(saved_result[0].wdata),
    .saved_a_wstrb(saved_result[0].strb),
    .saved_b_seq(saved_result[1].seq),
    .saved_b_addr(saved_result[1].addr),
    .saved_b_write(saved_result[1].wr),
    .saved_b_size(saved_result[1].size),
    .saved_b_burst(saved_result[1].burst),
    .saved_b_prot(saved_result[1].prot),
    .saved_b_trans(saved_result[1].trans),
    .saved_b_lock(saved_result[1].lock),
    .saved_b_wdata(saved_result[1].wdata),
    .saved_b_wstrb(saved_result[1].strb),
    .match_valid,.match_ready,.fault_valid,.fault_reason,.result_seq
  );
  bit occupied[2],paired_once[2],authorized[2],got_response[2],result_pending=0;
  integer accepts[2],completions[2],cancels[2],responses[2];
  integer handoffs=0,dispatches=0,trace_fd,case_fd,cases=0;
  string case_name="reset";
  always @(posedge HCLK) begin
    $fdisplay(trace_fd,"%0t,%s,%b,%b,%b,%b,%b,%b,%b,%h,%b,%b,%b,%b,%b,%b,%b",$time,case_name,HRESETn,
      pair_valid,pair_ready,match_valid,match_ready,fault_valid,pending[0]&&ready[0],fault_reason,
      pending[1]&&ready[1],ready[0]&&trans[0][1],ready[1]&&trans[1][1],
      rsp_valid[0]&&rsp_ready[0],rsp_valid[1]&&rsp_ready[1],pending[0],pending[1]);
    if(!HRESETn) begin
      for(int side=0;side<2;side++) begin
        if(occupied[side]) cancels[side]++;
        occupied[side]=0;paired_once[side]=0;authorized[side]=0;got_response[side]=0;
      end
      result_pending=0;
    end else begin
      if(match_valid||fault_valid) begin
        assert(result_pending&&saved_result[0]===accepted_payload[0]&&saved_result[1]===accepted_payload[1]) else $fatal(1,"integration saved result/duplicate");
      end
      if(match_valid&&match_ready) begin
        assert(!fault_valid&&fault_reason==0&&occupied[0]&&occupied[1]&&paired_once[0]&&paired_once[1]) else $fatal;
        dispatches++;authorized[0]=1;authorized[1]=1;result_pending=0;
      end
      if(pair_valid&&pair_ready) begin
        assert(!result_pending&&occupied[0]&&occupied[1]&&!paired_once[0]&&!paired_once[1]) else $fatal;
        handoffs++;paired_once[0]=1;paired_once[1]=1;result_pending=1;
        accepted_payload[0]=paired[0];accepted_payload[1]=paired[1];
      end
      if(fault_valid) assert(!match_valid&&!pair_ready&&!ready[0]&&!ready[1]&&!resp[0]&&!resp[1]) else $fatal(1,"fault released upstream");
      for(int side=0;side<2;side++) begin
        if(rsp_valid[side]&&rsp_ready[side]) begin
          assert(authorized[side]&&!got_response[side]) else $fatal(1,"fake response before successful dispatch");
          got_response[side]=1;responses[side]++;
        end
        if(occupied[side]&&ready[side]) begin
          assert(authorized[side]&&got_response[side]&&rdata[side]==64'h12345678) else $fatal;
          completions[side]++;occupied[side]=0;paired_once[side]=0;authorized[side]=0;got_response[side]=0;
        end
        if(ready[side]&&trans[side][1]) begin assert(!occupied[side]) else $fatal;accepts[side]++;occupied[side]=1;end
      end
    end
  end
  task automatic tick;@(posedge HCLK);#2;@(negedge HCLK);endtask
  task automatic reset_all;
    HRESETn=0;match_ready=1;tick();
    assert(!match_valid&&!fault_valid&&!pair_ready&&fault_reason==0&&!pending[0]&&!pending[1]) else $fatal;
    for(int side=0;side<2;side++) begin trans[side]=0;rsp_valid[side]=0;end
    match_ready=0;HRESETn=1;tick();assert(ready[0]&&ready[1]&&pair_ready) else $fatal;
  endtask
  task automatic scenario(input string name,input integer skew,input bit write_req,input bit wrong_address,input integer blocked);
    integer ta,tb,span,before_pair,before_dispatch,before_complete;
    case_name=name;before_pair=handoffs;before_dispatch=dispatches;before_complete=completions[0];
    ta=skew<0 ? -skew : 0;tb=skew>0 ? skew : 0;span=ta>tb ? ta : tb;
    for(int t=0;t<=span;t++) begin
      for(int side=0;side<2;side++) begin
        trans[side]=t==(side==0 ? ta : tb) ? 2'b10 : 2'b00;
        addr[side]=(wrong_address&&side==1) ? 56'h200 : 56'h100;
        wr[side]=write_req;wdata[side]=t>(side==0 ? ta : tb) ? 64'hfeed1234 : 64'hbad;
        strb[side]=8'h81;rsp_data[side]=64'hcafebabe+64'(side);
      end
      tick();
      if(t<span) assert(!match_valid&&!fault_valid&&handoffs==before_pair) else $fatal(1,"compared before peer");
    end
    for(int side=0;side<2;side++) begin trans[side]=0;wdata[side]=64'hfeed1234;end
    while(!match_valid&&!fault_valid) tick();
    assert(handoffs==before_pair+1&&dispatches==before_dispatch&&!pair_valid) else $fatal;
    if(wrong_address) begin
      assert(fault_valid&&!match_valid&&fault_reason==11'h001) else $fatal;
      // Present the opposite order next. It cannot replace the mismatched heads.
      addr[0]=56'h200;addr[1]=56'h100;trans[0]=2;trans[1]=2;match_ready=1;
      repeat(4) tick();
      assert(dispatches==before_dispatch&&completions[0]==before_complete&&fault_valid) else $fatal;
      $fdisplay(case_fd,"%s,%0d,FAULT,%0d,%0d",name,skew,handoffs-before_pair,dispatches-before_dispatch);
      reset_all();
    end else begin
      assert(match_valid&&!fault_valid&&fault_reason==0) else $fatal;
      if(write_req) assert(saved_result[0].wdata==64'hfeed1234&&saved_result[1].wdata==64'hfeed1234&&saved_result[0].strb==8'h81) else $fatal;
      for(int side=0;side<2;side++) begin addr[side]=56'hbad;wdata[side]=64'hbad;rsp_data[side]='1;end
      repeat(blocked) begin tick();assert(match_valid&&dispatches==before_dispatch&&!ready[0]&&!ready[1]) else $fatal;end
      match_ready=1;tick();match_ready=0;
      assert(dispatches==before_dispatch+1&&!match_valid) else $fatal;
      // Test-only completion producer, triggered AFTER successful dispatch.
      for(int side=0;side<2;side++) begin rsp_valid[side]=1;rsp_data[side]=64'h12345678;end
      tick();for(int side=0;side<2;side++) rsp_valid[side]=0;
      tick();assert(completions[0]==before_complete+1&&!pending[0]&&!pending[1]) else $fatal;
      $fdisplay(case_fd,"%s,%0d,MATCH,%0d,%0d",name,skew,handoffs-before_pair,dispatches-before_dispatch);
    end
    cases++;
  endtask
  initial begin
    for(int side=0;side<2;side++) begin
      addr[side]=0;wdata[side]=0;strb[side]=0;wr[side]=0;lock[side]=0;
      size[side]=3;burst[side]=0;prot[side]=3;trans[side]=0;
      rsp_valid[side]=0;rsp_data[side]=0;rsp_resp[side]=0;
      occupied[side]=0;paired_once[side]=0;authorized[side]=0;got_response[side]=0;
      accepts[side]=0;completions[side]=0;cancels[side]=0;responses[side]=0;
    end
    trace_fd=$fopen("integration-events.csv","w");case_fd=$fopen("integration-cases.csv","w");assert(trace_fd!=0&&case_fd!=0) else $fatal;
    $fdisplay(trace_fd,"time_ps,case,resetn,pair_valid,pair_ready,match_valid,match_ready,fault_valid,a_complete,reason,b_complete,a_accept,b_accept,a_response,b_response,a_pending,b_pending");
    $fdisplay(case_fd,"case,skew,result,handoffs,dispatches");
    $dumpfile("compare-ingress.vcd");$dumpvars;
    tick();reset_all();
    scenario("simultaneous_read",0,0,0,0);
    scenario("a_early",3,0,0,2);
    scenario("b_early",-2,0,0,0);
    scenario("write_backpressure",0,1,0,4);
    repeat(2) scenario("repeated_address",0,0,0,0);
    scenario("different_order_heads",0,0,1,0);
    scenario("post_fault_common_reset",0,0,0,0);
    assert(handoffs==8&&dispatches==7&&accepts[0]==8&&accepts[1]==8&&completions[0]==7&&completions[1]==7&&cancels[0]==1&&cancels[1]==1) else $fatal;
    $display("COMPARE_INGRESS_TEST_PASS cases=%0d handoffs=%0d dispatches=%0d A_complete=%0d B_complete=%0d A_cancel=%0d B_cancel=%0d",cases,handoffs,dispatches,completions[0],completions[1],cancels[0],cancels[1]);
    $fclose(trace_fd);$fclose(case_fd);$finish;
  end
  initial begin #10000;$fatal(1,"Compare ingress timeout");end
endmodule
