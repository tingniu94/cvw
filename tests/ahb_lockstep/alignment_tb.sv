// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Synthetic AHB agents and an independent acceptance/pair/completion ledger.
module alignment_tb;
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
  logic pair_valid, pair_ready=0;
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

  request_t saved[2], held_a, held_b;
  logic [SEQ_WIDTH-1:0] next_seq[2], next_pair=0, held_seq;
  bit occupied[2], need_data[2], sent[2], response_seen[2];
  logic [63:0] saved_response[2];
  bit held=0;
  longint unsigned exp_wait=0, exp_a_wait=0, exp_b_wait=0, exp_bp=0, exp_pairs=0;
  int accepts[2], completions[2], cancels[2], dispatches[2], responses[2];
  int total_pairs=0, cycles=0, checks=0, trace_fd, cases_fd;
  string case_name="initial_reset";

  task automatic check_counters;
    assert(pairing_wait_cycles==exp_wait && a_peer_wait_cycles==exp_a_wait &&
           b_peer_wait_cycles==exp_b_wait && pair_backpressure_cycles==exp_bp &&
           paired_requests==exp_pairs && pair_seq==next_pair)
      else $fatal(1,"counter mismatch at %0t case=%s",$time,case_name);
    assert(pairing_wait_cycles==a_peer_wait_cycles+b_peer_wait_cycles) else $fatal;
    checks++;
  endtask

  always @(posedge HCLK) begin : ledger
    bit available[2];
    // Hardware counters asynchronously clear at reset assertion; reference
    // accounting flushes below on this edge, so compare pre-edge only live.
    if (HRESETn) check_counters();
    $fdisplay(trace_fd,"%0t,%s,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%0d,%0d,%0d,%0d,%0d,%0d,%b,%b",
      $time,case_name,HRESETn,ready[0],ready[1],trans[0][1],trans[1][1],
      pending[0],pending[1],req_valid[0],req_valid[1],pair_valid,pair_ready,
      rsp_valid[0]&&rsp_ready[0],rsp_valid[1]&&rsp_ready[1],
      pair_valid&&pair_ready,pair_seq,pairing_wait_cycles,a_peer_wait_cycles,
      b_peer_wait_cycles,pair_backpressure_cycles,paired_requests,
      HRESETn&&occupied[0]&&ready[0],HRESETn&&occupied[1]&&ready[1]);
    if (!HRESETn) begin
      assert(!pair_valid && !ready[0] && !ready[1] && !rsp_ready[0] && !rsp_ready[1]) else $fatal;
      for(int side=0;side<2;side++) begin
        if(occupied[side]) cancels[side]++;
        occupied[side]=0; need_data[side]=0; sent[side]=0; response_seen[side]=0;
        saved[side]='0; next_seq[side]=0;
      end
      exp_wait=0;exp_a_wait=0;exp_b_wait=0;exp_bp=0;exp_pairs=0;next_pair=0;held=0;
    end else begin
      for(int side=0;side<2;side++) begin
        available[side]=occupied[side] && !need_data[side] && !sent[side];
        assert(req_valid[side]==available[side] && pending[side]==occupied[side])
          else $fatal(1,"public ingress status at %0t side=%0d",$time,side);
        if(available[side]) assert(paired[side]===saved[side])
          else $fatal(1,"saved payload changed side=%0d seq=%0d",side,next_pair);
      end
      assert(pair_valid==(available[0]&&available[1])) else $fatal;
      if(held) assert(pair_valid && paired[0]===held_a && paired[1]===held_b && pair_seq==held_seq)
        else $fatal(1,"backpressured pair overwritten");
      held=pair_valid&&!pair_ready;
      if(held) begin held_a=paired[0];held_b=paired[1];held_seq=pair_seq; end
      if(available[0]&&!available[1]) begin exp_wait++;exp_a_wait++; end
      if(available[1]&&!available[0]) begin exp_wait++;exp_b_wait++; end
      if(pair_valid&&!pair_ready) exp_bp++;
      if(pair_valid&&pair_ready) begin
        for(int side=0;side<2;side++) begin
          assert(occupied[side]&&!sent[side]&&paired[side].seq==next_pair)
            else $fatal(1,"duplicate/cross-transaction pairing");
          sent[side]=1; dispatches[side]++;
        end
        $display("[PAIR] time=%0t case=%s seq=%0d A=%h B=%h",$time,case_name,pair_seq,paired[0].addr,paired[1].addr);
        total_pairs++;exp_pairs++;next_pair=next_pair+1'b1;
      end
      for(int side=0;side<2;side++) begin
        if(need_data[side]) begin
          saved[side].wdata=wdata[side];saved[side].strb=strb[side];need_data[side]=0;
        end
        if(rsp_valid[side]&&rsp_ready[side]) begin
          assert(occupied[side]&&sent[side]&&!response_seen[side]) else $fatal(1,"phantom response");
          response_seen[side]=1;saved_response[side]=rsp_data[side];responses[side]++;
        end
        // Complete old data before accepting a possible pipelined next address.
        if(occupied[side]&&ready[side]) begin
          assert(sent[side]&&response_seen[side]&&rdata[side]==saved_response[side]&&!resp[side])
            else $fatal(1,"premature/wrong completion side=%0d",side);
          completions[side]++;occupied[side]=0;sent[side]=0;response_seen[side]=0;
        end
        if(ready[side]&&trans[side][1]) begin
          assert(!occupied[side]) else $fatal(1,"pending overwritten");
          occupied[side]=1;sent[side]=0;need_data[side]=wr[side];response_seen[side]=0;
          saved[side]='{seq:next_seq[side],addr:addr[side],wr:wr[side],size:size[side],
            burst:burst[side],prot:prot[side],trans:trans[side],lock:lock[side],wdata:64'd0,strb:8'd0};
          next_seq[side]=next_seq[side]+1'b1;accepts[side]++;
        end
      end
    end
    cycles++;
    #1;check_counters();
  end

  // Every stimulus change below occurs at a negedge; checks after tick see
  // settled monitor and NBA state, never race rising-edge sampling.
  task automatic tick;
    @(posedge HCLK);#2;@(negedge HCLK);
  endtask
  task automatic idle_bus;
    for(int side=0;side<2;side++) begin
      trans[side]=0;rsp_valid[side]=0;wr[side]=0;
    end
  endtask
  task automatic respond_both;
    assert(rsp_ready[0]&&rsp_ready[1]) else $fatal;
    for(int side=0;side<2;side++) begin rsp_valid[side]=1;rsp_data[side]=64'hface0000+64'(side);end
    tick();
    for(int side=0;side<2;side++) rsp_valid[side]=0;
    tick();
    assert(!pending[0]&&!pending[1]&&ready[0]&&ready[1]) else $fatal;
  endtask
  task automatic reset_all;
    HRESETn=0; pair_ready=1;
    tick();
    assert(!pair_valid&&!pending[0]&&!pending[1]&&pairing_wait_cycles==0&&paired_requests==0) else $fatal;
    idle_bus();pair_ready=0;HRESETn=1;
    tick();
    assert(ready[0]&&ready[1]&&!pair_valid&&pair_seq==0) else $fatal;
  endtask

  task automatic run_case(input string name,input int skew,input bit write_a,input bit write_b,input int backpressure);
    int at_a,at_b,span,expected_wait;
    longint unsigned wait_start,bp_start,pair_start;
    case_name=name;
    assert(ready[0]&&ready[1]) else $fatal;
    wait_start=pairing_wait_cycles;bp_start=pair_backpressure_cycles;pair_start=paired_requests;
    at_a=skew<0 ? -skew : 0;at_b=skew>0 ? skew : 0;
    span=at_a>at_b ? at_a : at_b;
    expected_wait=(at_a+int'(write_a))-(at_b+int'(write_b));
    if(expected_wait<0) expected_wait=-expected_wait;
    pair_ready=0;
    for(int t=0;t<=span;t++) begin
      for(int side=0;side<2;side++) begin
        trans[side]=t==(side==0 ? at_a : at_b) ? 2'b10 : 2'b00;
        addr[side]=56'h100;wr[side]=side==0 ? write_a : write_b;
        // At address acceptance use an unrelated sentinel, then the real data.
        wdata[side]=t>(side==0 ? at_a : at_b) ? 64'h12340000+64'(side) : 64'hbad;
        strb[side]=t>(side==0 ? at_a : at_b) ? 8'h81 : 8'h00;
      end
      tick();
      if(t<span) begin
        if(skew>0) assert(!ready[0]&&ready[1]) else $fatal;
        else assert(ready[0]&&!ready[1]) else $fatal;
      end
    end
    idle_bus();
    for(int side=0;side<2;side++) begin wdata[side]=64'h12340000+64'(side);strb[side]=8'h81;end
    while(!pair_valid) tick();
    assert(pairing_wait_cycles-wait_start==64'(expected_wait)) else $fatal(1,"peer wait case=%s",name);
    for(int side=0;side<2;side++) if(side==0 ? write_a : write_b)
      assert(paired[side].wdata==64'h12340000+64'(side)&&paired[side].strb==8'h81) else $fatal;
    // Change live address/data while blocked: saved pair must not change.
    for(int side=0;side<2;side++) begin addr[side]=56'hf00;wdata[side]=64'hbadbad;strb[side]=8'hff;end
    repeat(backpressure) tick();
    assert(pairing_wait_cycles-wait_start==64'(expected_wait)&&pair_backpressure_cycles-bp_start==64'(backpressure)) else $fatal;
    pair_ready=1;tick();pair_ready=0;
    assert(!pair_valid&&paired_requests==pair_start+1&&rsp_ready[0]&&rsp_ready[1]) else $fatal;
    $fdisplay(cases_fd,"%s,%0d,%0d,%0d,%0d,%0d,%0d",name,skew,write_a,write_b,expected_wait,pairing_wait_cycles-wait_start,pair_backpressure_cycles-bp_start);
    respond_both();
  endtask

  initial begin
    for(int side=0;side<2;side++) begin
      addr[side]=0;wdata[side]=0;strb[side]=0;wr[side]=0;lock[side]=0;
      size[side]=3;burst[side]=0;prot[side]=3;trans[side]=0;
      rsp_valid[side]=0;rsp_data[side]=0;rsp_resp[side]=0;
      saved[side]='0;occupied[side]=0;need_data[side]=0;sent[side]=0;response_seen[side]=0;next_seq[side]=0;
      accepts[side]=0;completions[side]=0;cancels[side]=0;dispatches[side]=0;responses[side]=0;
    end
    trace_fd=$fopen("alignment-cycles.csv","w");cases_fd=$fopen("pairing-cases.csv","w");
    assert(trace_fd!=0&&cases_fd!=0) else $fatal;
    $fdisplay(trace_fd,"time_ps,case,resetn,a_ready,b_ready,a_trans_valid,b_trans_valid,a_pending,b_pending,a_req_valid,b_req_valid,pair_valid,pair_ready,a_rsp_capture,b_rsp_capture,pair_handshake,pair_seq,wait_cycles,a_wait,b_wait,backpressure,pairs,a_complete,b_complete");
    $fdisplay(cases_fd,"case,skew,write_a,write_b,expected_peer_wait,measured_peer_wait,backpressure");
    $dumpfile("alignment.vcd");$dumpvars;
    tick();reset_all();
    run_case("simultaneous_read",0,0,0,0);
    run_case("a_early_1",1,0,0,0);
    run_case("a_early_4",4,0,0,0);
    run_case("b_early_3",-3,0,0,0);
    run_case("simultaneous_write",0,1,1,0);
    run_case("a_early_write",2,1,1,0);
    run_case("b_early_write",-2,1,1,0);
    run_case("backpressure_both",0,0,0,5);
    run_case("skew_plus_backpressure",3,0,0,4);
    // Mismatching direction/data/control intentionally handed off unchanged.
    // Step 3C joins ordinals; Step 3D must decide whether this is legal to issue.
    prot[1]=4'hf;lock[1]=1;size[1]=0;burst[1]=5;
    run_case("payload_not_compared",0,0,1,2);
    for(int side=0;side<2;side++) begin prot[side]=3;lock[side]=0;size[side]=3;burst[side]=0;end
    // Repeated identical addresses and ordinal wrap must not coalesce requests.
    for(int n=0;n<4;n++) run_case("repeated_address",0,0,0,0);

    case_name="asymmetric_response_overlap";
    pair_ready=1;trans[0]=2;trans[1]=2;addr[0]=56'h200;addr[1]=56'h200;
    tick();idle_bus();tick(); // pair dispatch
    rsp_valid[0]=1;rsp_data[0]=64'haaaa;tick();rsp_valid[0]=0;
    trans[0]=2;addr[0]=56'h208;tick();trans[0]=0; // A completes old + accepts next
    assert(req_valid[0]&&!req_valid[1]&&!pair_valid&&rsp_ready[1]) else $fatal;
    repeat(2) tick(); // never pair A(n+1) with B(n) awaiting response
    rsp_valid[1]=1;rsp_data[1]=64'hbbbb;tick();rsp_valid[1]=0;
    trans[1]=2;addr[1]=56'h208;tick();trans[1]=0; // B completes old + next address
    assert(pair_valid&&paired[0].addr==56'h208&&paired[1].addr==56'h208) else $fatal;
    tick();pair_ready=0;respond_both();

    case_name="reset_a_waiting";trans[0]=2;addr[0]=56'h300;
    tick();idle_bus();repeat(3) tick();reset_all();
    case_name="reset_b_write_capture";trans[1]=2;wr[1]=1;addr[1]=56'h310;
    tick();reset_all(); // pending metadata, write data not yet complete
    case_name="reset_both_backpressured";trans[0]=2;trans[1]=2;
    tick();idle_bus();repeat(2) tick();reset_all();
    case_name="reset_after_dispatch";trans[0]=2;trans[1]=2;pair_ready=1;
    tick();idle_bus();tick();
    assert(rsp_ready[0]&&rsp_ready[1]) else $fatal;
    reset_all();
    run_case("post_reset_sequence_zero",0,0,0,0);
    // IDLE/BUSY and stray response while EMPTY must not create a pair.
    case_name="idle_busy";trans[0]=1;trans[1]=0;rsp_valid[0]=1;rsp_valid[1]=1;
    repeat(3) tick();idle_bus();
    assert(!pair_valid&&!pending[0]&&!pending[1]) else $fatal;
    for(int side=0;side<2;side++) assert(accepts[side]==completions[side]+cancels[side]&&dispatches[side]==total_pairs) else $fatal;
    $display("ALIGNMENT_TEST_PASS cycles=%0d checks=%0d pairs=%0d A_accept=%0d B_accept=%0d A_complete=%0d B_complete=%0d A_cancel=%0d B_cancel=%0d",
      cycles,checks,total_pairs,accepts[0],accepts[1],completions[0],completions[1],cancels[0],cancels[1]);
    $fclose(trace_fd);$fclose(cases_fd);$finish;
  end
  initial begin #20000;$fatal(1,"Alignment deadlock timeout");end
endmodule
