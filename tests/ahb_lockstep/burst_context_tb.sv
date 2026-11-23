// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module burst_context_tb;
  parameter integer AW=56,DW=64;
  parameter bit ENABLE=1;
  logic clk=0,resetn=0,valid=0,credit=1,ready,auth,reject;
  logic [AW-1:0] addr=0,expected;
  logic wr=0,lock=0;
  logic [2:0] size=3'($clog2(DW/8)),burst=0,index;
  logic [1:0] trans=2;
  logic [3:0] prot=3,ac,cc;
  logic accept=0,complete=0,ending=0,cmpfault=0,fault,active,pending,data;
  logic [8:0] reason;
  integer authorizations=0,acceptances=0,completions=0,cases=0;
  integer epoch_auth=0,epoch_accept=0,epoch_complete=0;
  always @(posedge clk) begin
    if(!resetn) begin epoch_auth=0;epoch_accept=0;epoch_complete=0;end
    else begin
      if(auth) epoch_auth++;
      if(accept && pending && !data) epoch_accept++;
      if(complete && data) epoch_complete++;
      // Only intentionally malformed scheduler tests may violate this ledger.
      if(!accept && !complete)
        assert(epoch_complete<=epoch_accept && epoch_accept<=epoch_auth)
          else $fatal(1,"duplicate or unowned event");
    end
  end
  localparam integer STEP=DW/8;
  always #5 clk=~clk;
  ahb_lockstep_burst_context #(.ADDR_WIDTH(AW),.DATA_WIDTH(DW),.ENABLE_INCR8(ENABLE)) dut(
    .HCLK(clk),.HRESETn(resetn),.cmd_valid(valid),.consumer_ready(credit),
    .cmd_ready(ready),.authorized(auth),.rejected(reject),.cmd_addr(addr),
    .cmd_write(wr),.cmd_lock(lock),.cmd_size(size),.cmd_burst(burst),
    .cmd_trans(trans),.cmd_prot(prot),.down_accept(accept),.down_complete(complete),
    .end_burst(ending),.compare_fault(cmpfault),.fault(fault),.fault_reason(reason),
    .burst_active(active),.beat_pending(pending),.waiting_data(data),.beat_index(index),
    .accepted_count(ac),.completed_count(cc),.expected_addr(expected));
  always @(posedge clk) if(resetn) begin
    if(auth) authorizations=authorizations+1;
    if(accept) acceptances=acceptances+1;
    if(complete) completions=completions+1;
  end
  task automatic tick;
    @(posedge clk); #1;
  endtask
  task automatic drive;
    @(negedge clk);
  endtask
  task automatic reset;
    drive();resetn=0;valid=0;accept=0;complete=0;ending=0;cmpfault=0;
    credit=1;addr=0;wr=0;lock=0;size=3'($clog2(DW/8));burst=0;trans=2;prot=3;
    tick(); assert(!fault&&!active&&!pending&&ac==0&&cc==0) else $fatal(1,"reset");
    drive();resetn=1;
  endtask
  task automatic issue(input integer a,input bit first);
    drive();addr=AW'(a);trans=first?2'b10:2'b11;valid=1;
    #1;assert(auth) else $fatal(1,"expected authorization addr=%h reason=%h",addr,dut.reasons);
    tick();drive();valid=0;
    repeat(2) tick();
    assert(pending&&!data&&ac==cc) else $fatal(1,"authorization is not acceptance");
    drive();accept=1;tick();drive();accept=0;
    assert(data&&ac==cc+1) else $fatal(1,"acceptance accounting");
  endtask
  task automatic finish_data;
    repeat(2) tick();drive();complete=1;tick();drive();complete=0;
    assert(!pending&&ac==cc) else $fatal(1,"completion accounting");
  endtask
  task automatic bad(input integer bitno);
    drive();valid=1;#1;
    assert(reject&&!auth) else $fatal(1,"expected rejection");
    tick();assert(fault&&reason[bitno]) else $fatal(1,"reason %h expected %0d",reason,bitno);
    drive();valid=0;repeat(2) tick();
    assert(!auth&&!ready) else $fatal(1,"sticky fault");cases++;
  endtask
  initial begin
    $dumpfile("burst-context.fst");$dumpvars(0,burst_context_tb);
    reset();issue(256,1);finish_data();assert(!active&&ac==1&&cc==1) else $fatal;
    cases++;
    if(!ENABLE) begin
      reset();burst=5;bad(0);
    end else begin
      reset();burst=5;
      for(integer i=0;i<8;i++) begin
        assert(index==3'(i)) else $fatal(1,"index");
        issue(256+i*STEP,i==0);
        assert(active) else $fatal(1,"burst cleared at address acceptance");
        if(i==7) begin
          assert(ac==8&&cc==7&&index==7) else $fatal(1,"final pending data");
          // No new command can enter while final data is outstanding.
          assert(!ready) else $fatal;
        end
        finish_data();
        if(i<7) begin
          assert(active&&expected==(AW'(256)+AW'(i+1)*AW'(STEP))) else $fatal;
          // Idle cycles / BUSY scheduling are NOT end_burst events.
          repeat(3) tick();assert(ac==4'(i+1)&&cc==4'(i+1)) else $fatal;
        end
      end
      assert(!active&&ac==8&&cc==8) else $fatal;cases++;
      for(integer testno=0;testno<6;testno++) begin
        reset();burst=5;issue(256,1);finish_data();
        addr=AW'(256+STEP);trans=3;
        case(testno)
          0: begin addr=AW'(256+2*STEP);bad(4);end
          1: begin size=0;bad(5);end
          2: begin wr=1;bad(5);end
          3: begin trans=2;bad(3);end
          4: begin burst=0;bad(5);end
          5: begin prot=0;bad(5);end
        endcase
      end
      reset();burst=5;trans=3;bad(3);
      reset();burst=5;addr=AW'(1024-STEP);bad(2);
      reset();burst=5;issue(256,1);finish_data();drive();ending=1;tick();
      assert(fault&&reason[6]&&ac==1&&cc==1) else $fatal;cases++;
      reset();burst=5;issue(256,1);drive();cmpfault=1;tick();
      assert(fault&&reason[7]&&ac==1&&cc==0) else $fatal;
      drive();cmpfault=0;complete=1;tick();drive();complete=0;
      assert(cc==1&&!auth&&fault) else $fatal;cases++;
      reset();burst=5;issue(256,1);reset();cases++;
      // Both directions and all legal transfer sizes, including exact 1KB end.
      for(integer direction=0;direction<2;direction++) begin
        for(integer sz=0;sz<=$clog2(DW/8);sz++) begin
          reset();burst=5;wr=1'(direction);size=3'(sz);
          for(integer i=0;i<8;i++) begin
            issue(1024-8*(1<<sz)+i*(1<<sz),i==0);finish_data();
          end
          assert(!active&&epoch_auth==8&&epoch_accept==8&&epoch_complete==8)
            else $fatal(1,"per-beat ledger");
          cases++;
        end
      end
      // Explicit termination after address 8 is still premature before data 8.
      reset();burst=5;
      for(integer i=0;i<8;i++) begin
        issue(256+i*STEP,i==0);if(i<7) finish_data();
      end
      drive();ending=1;tick();
      assert(fault&&reason[6]&&active&&ac==8&&cc==7&&index==7) else $fatal;
      drive();ending=0;complete=1;tick();drive();complete=0;
      assert(fault&&!active&&cc==8) else $fatal;cases++;
      // Normal explicit end is allowed on the final data completion edge.
      reset();burst=5;
      for(integer i=0;i<8;i++) begin
        issue(256+i*STEP,i==0);if(i<7) finish_data();
      end
      drive();ending=1;complete=1;tick();drive();ending=0;complete=0;
      assert(!fault&&!active&&cc==8) else $fatal;cases++;
      reset();burst=5;credit=0;valid=1;repeat(3) tick();
      assert(!auth&&!pending&&ac==0) else $fatal;
      drive();credit=1;tick();drive();valid=0;
      assert(pending&&ac==0) else $fatal;reset();cases++;
    end
    reset();addr=1;bad(1);
    reset();lock=1;bad(0);
    reset();size=7;bad(0);
    reset();burst=3;bad(0);
    reset();trans=0;bad(3);
    reset();trans=1;bad(3);
    reset();drive();complete=1;tick();assert(fault&&reason[8]) else $fatal;cases++;
    reset();drive();accept=1;tick();assert(fault&&reason[8]) else $fatal;cases++;
    reset();
    $display("F1_PASS cases=%0d authorizations=%0d accepts=%0d completes=%0d",cases,authorizations,acceptances,completions);
    $finish;
  end
endmodule
