// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Independent expected-mask oracle; all parameterized payload bits are swept.
module compare_tb;
  parameter integer AW=56, DW=64, SW=DW/8, QW=32;
  logic HCLK=0,HRESETn=0;
  always #5 HCLK=~HCLK;
  typedef struct packed {
    logic [QW-1:0] seq;
    logic [AW-1:0] addr;
    logic wr;
    logic [2:0] size,burst;
    logic [3:0] prot;
    logic [1:0] trans;
    logic lock;
    logic [DW-1:0] wdata;
    logic [SW-1:0] strb;
  } request_t;
  request_t a,b,sa,sb,base_req,ea,eb;
  logic pair_valid=0,pair_ready,match_valid,match_ready=0,fault_valid;
  logic [QW-1:0] pair_seq=0,result_seq;
  logic [10:0] fault_reason;
  integer case_fd,event_fd,tests=0,accepted=0,dispatched=0,fault_tests=0,match_tests=0;
  string test_name="reset";
  ahb_lockstep_compare #(.ADDR_WIDTH(AW),.DATA_WIDTH(DW),.STRB_WIDTH(SW),.SEQ_WIDTH(QW)) dut(
    .HCLK,.HRESETn,.pair_valid,.pair_ready,.pair_seq,
    .pair_a_seq(a.seq),
    .pair_a_addr(a.addr),
    .pair_a_write(a.wr),
    .pair_a_size(a.size),
    .pair_a_burst(a.burst),
    .pair_a_prot(a.prot),
    .pair_a_trans(a.trans),
    .pair_a_lock(a.lock),
    .pair_a_wdata(a.wdata),
    .pair_a_wstrb(a.strb),
    .pair_b_seq(b.seq),
    .pair_b_addr(b.addr),
    .pair_b_write(b.wr),
    .pair_b_size(b.size),
    .pair_b_burst(b.burst),
    .pair_b_prot(b.prot),
    .pair_b_trans(b.trans),
    .pair_b_lock(b.lock),
    .pair_b_wdata(b.wdata),
    .pair_b_wstrb(b.strb),
    .saved_a_seq(sa.seq),
    .saved_a_addr(sa.addr),
    .saved_a_write(sa.wr),
    .saved_a_size(sa.size),
    .saved_a_burst(sa.burst),
    .saved_a_prot(sa.prot),
    .saved_a_trans(sa.trans),
    .saved_a_lock(sa.lock),
    .saved_a_wdata(sa.wdata),
    .saved_a_wstrb(sa.strb),
    .saved_b_seq(sb.seq),
    .saved_b_addr(sb.addr),
    .saved_b_write(sb.wr),
    .saved_b_size(sb.size),
    .saved_b_burst(sb.burst),
    .saved_b_prot(sb.prot),
    .saved_b_trans(sb.trans),
    .saved_b_lock(sb.lock),
    .saved_b_wdata(sb.wdata),
    .saved_b_wstrb(sb.strb),
    .match_valid,.match_ready,.fault_valid,.fault_reason,.result_seq
  );
  always @(posedge HCLK) begin
    if(HRESETn&&pair_valid&&pair_ready) accepted++;
    if(HRESETn&&match_valid&&match_ready) dispatched++;
    $fdisplay(event_fd,"%0t,%s,%b,%b,%b,%b,%b,%b,%h,%0d",$time,test_name,HRESETn,
      pair_valid,pair_ready,match_valid,match_ready,fault_valid,fault_reason,result_seq);
    assert(!(match_valid&&fault_valid)) else $fatal;
  end
  task automatic tick;
    @(posedge HCLK);#2;@(negedge HCLK);
  endtask
  task automatic reset_cmp;
    HRESETn=0;pair_valid=1;match_ready=1;tick();
    assert(!pair_ready&&!match_valid&&!fault_valid&&fault_reason==0&&sa=='0&&sb=='0&&result_seq==0) else $fatal(1,"reset clear");
    pair_valid=0;match_ready=0;HRESETn=1;tick();
    assert(pair_ready&&!match_valid&&!fault_valid) else $fatal;
  endtask
  task automatic check_result(input logic [10:0] mask,input logic [QW-1:0] ordinal);
    assert(sa===ea&&sb===eb&&result_seq==ordinal&&fault_reason==mask)
      else $fatal(1,"saved result changed case=%s mask=%h expected=%h",test_name,fault_reason,mask);
    assert(match_valid==(mask==0)&&fault_valid==(mask!=0)&&!pair_ready)
      else $fatal(1,"result qualification case=%s",test_name);
  endtask
  task automatic exercise(input string name,input request_t aa,input request_t bb,
                          input logic [QW-1:0] ordinal,input logic [10:0] expected);
    integer before_accept,before_dispatch;
    assert(pair_ready) else $fatal;
    test_name=name;before_accept=accepted;before_dispatch=dispatched;
    a=aa;b=bb;ea=aa;eb=bb;pair_seq=ordinal;pair_valid=1;match_ready=0;
    // No combinational match before the acceptance edge.
    #1;assert(!match_valid&&!fault_valid) else $fatal;
    tick();pair_valid=0;
    assert(accepted==before_accept+1&&dispatched==before_dispatch) else $fatal;
    check_result(expected,ordinal);
    // Mutate all source fields after consumption, while blocking dispatch.
    a='1;b='0;pair_seq='1;
    repeat(3) begin tick();check_result(expected,ordinal);end
    if(expected==0) begin
      // Present a next pair during occupied output: input cannot consume it.
      pair_valid=1;match_ready=1;
      tick();pair_valid=0;match_ready=0;
      assert(dispatched==before_dispatch+1&&accepted==before_accept+1&&pair_ready&&!match_valid&&!fault_valid) else $fatal(1,"duplicate dispatch or overwritten slot");
      repeat(2) tick();assert(dispatched==before_dispatch+1) else $fatal;
      match_tests++;
    end else begin
      // Fault receipt is independent of match_ready. A later good pair must
      // not overwrite fault evidence; neither fault nor later request dispatch.
      a=base_req;b=base_req;pair_seq=base_req.seq;pair_valid=1;match_ready=1;
      repeat(3) begin tick();check_result(expected,ordinal);end
      assert(dispatched==before_dispatch&&accepted==before_accept+1) else $fatal(1,"fault leaked success");
      pair_valid=0;fault_tests++;
    end
    tests++;
    $fdisplay(case_fd,"%0d,%s,%0t,%h,%h,%h,%h,%h,%h,%0d,%0d,%0d",tests,name,$time,expected,
      fault_reason,ea,eb,sa,sb,accepted,dispatched,result_seq);
    // sa/sb remain snapshots after successful dispatch until the next accept.
    if(expected!=0) reset_cmp();
  endtask
  initial begin
    a='0;b='0;ea='0;eb='0;base_req='0;
    case_fd=$fopen("compare-cases.csv","w");event_fd=$fopen("compare-events.csv","w");
    assert(case_fd!=0&&event_fd!=0) else $fatal;
    $fdisplay(case_fd,"id,case,time_ps,expected_mask,actual_mask,input_a,input_b,saved_a,saved_b,accepted,dispatched,result_seq");
    $fdisplay(event_fd,"time_ps,case,resetn,pair_valid,pair_ready,match_valid,match_ready,fault_valid,reason,result_seq");
    $dumpfile("compare.vcd");$dumpvars;
    tick();reset_cmp();
    base_req.seq=QW'(7);base_req.addr=AW'('h80001000);base_req.size=DW==32 ? 3'd2 : 3'd3;
    base_req.trans=2;pair_seq=base_req.seq;
    exercise("read_match",base_req,base_req,base_req.seq,0);
    a=base_req;b=base_req;b.wdata='1;b.strb='1;
    exercise("read_ignores_write_lanes",a,b,base_req.seq,0);
    base_req.wr=1;base_req.wdata=DW'('h123456789abcdef0);base_req.strb='1;
    exercise("write_match",base_req,base_req,base_req.seq,0);
    // Repeated requests are distinct, even with the same address and ordinal.
    repeat(2) exercise("repeated_address",base_req,base_req,base_req.seq,0);
    for(int i=0;i<AW;i++) begin b=base_req;b.addr[i]=~b.addr[i];exercise($sformatf("addr_bit_%0d",i),base_req,b,base_req.seq,11'h001);end
    b=base_req;b.wr=0;exercise("direction",base_req,b,base_req.seq,11'h002);
    for(int i=0;i<3;i++) begin b=base_req;b.size[i]=~b.size[i];exercise($sformatf("size_bit_%0d",i),base_req,b,base_req.seq,11'h004);end
    for(int i=0;i<3;i++) begin b=base_req;b.burst[i]=~b.burst[i];exercise($sformatf("burst_bit_%0d",i),base_req,b,base_req.seq,11'h008);end
    for(int i=0;i<4;i++) begin b=base_req;b.prot[i]=~b.prot[i];exercise($sformatf("prot_bit_%0d",i),base_req,b,base_req.seq,11'h010);end
    b=base_req;b.trans=3;exercise("nonseq_seq",base_req,b,base_req.seq,11'h020);
    b=base_req;b.lock=1;exercise("lock",base_req,b,base_req.seq,11'h040);
    for(int i=0;i<DW;i++) begin b=base_req;b.wdata[i]=~b.wdata[i];exercise($sformatf("data_bit_%0d",i),base_req,b,base_req.seq,11'h080);end
    for(int i=0;i<SW;i++) begin b=base_req;b.strb[i]=~b.strb[i];exercise($sformatf("strobe_bit_%0d",i),base_req,b,base_req.seq,11'h100);end
    a=base_req;a.strb='0;b=a;b.wdata[0]=~b.wdata[0];
    exercise("full_data_even_zero_strobe",a,b,base_req.seq,11'h080);
    for(int i=0;i<QW;i++) begin b=base_req;b.seq[i]=~b.seq[i];exercise($sformatf("local_seq_bit_%0d",i),base_req,b,base_req.seq,11'h200);end
    for(int i=0;i<QW;i++) exercise($sformatf("pair_seq_bit_%0d",i),base_req,base_req,base_req.seq^(QW'(1)<<i),11'h200);
    b=base_req;b.trans=0;exercise("invalid_idle",base_req,b,base_req.seq,11'h400);
    b.trans=1;exercise("invalid_busy",base_req,b,base_req.seq,11'h400);
    b=base_req;b.addr[0]=~b.addr[0];b.wdata[DW-1]=~b.wdata[DW-1];b.strb[SW-1]=~b.strb[SW-1];
    exercise("multiple_reasons",base_req,b,base_req.seq,11'h181);
    base_req.wr=0;base_req.burst=5;base_req.trans=3;
    exercise("equal_burst_metadata",base_req,base_req,base_req.seq,0);
    // Reset an authorized-but-undelivered MATCH: no dispatch may occur.
    test_name="reset_pending_match";a=base_req;b=base_req;pair_seq=base_req.seq;pair_valid=1;
    tick();pair_valid=0;assert(match_valid) else $fatal;
    begin
      integer dispatched_before;
      dispatched_before=dispatched;reset_cmp();
      assert(dispatched==dispatched_before) else $fatal(1,"reset pending leaked dispatch");
    end
    exercise("recovery_after_reset",base_req,base_req,base_req.seq,0);
    assert(accepted==tests+1&&dispatched==match_tests&&tests==match_tests+fault_tests) else $fatal;
    $display("COMPARE_TEST_PASS AW=%0d DW=%0d SW=%0d QW=%0d cases=%0d matches=%0d faults=%0d accepted=%0d dispatched=%0d reset_cancelled_match=1",
      AW,DW,SW,QW,tests,match_tests,fault_tests,accepted,dispatched);
    $fclose(case_fd);$fclose(event_fd);$finish;
  end
  initial begin #100000;$fatal(1,"Compare unit timeout");end
endmodule
