// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// MODULE_LEVEL_ONLY: public inhibit input, not an injected full-Guard mismatch.
module f3a_output_tb;
  logic HCLK=0,HRESETn=0,inhibit=0,match_valid=0,match_ready;
  always #5 HCLK=~HCLK;
  logic [7:0] match_seq=0,owner_seq;
  logic [55:0] cmd_addr=0,M_HADDR;
  logic cmd_write=1,cmd_lock=0;
  logic [2:0] cmd_size=3,cmd_burst=5,M_HSIZE,M_HBURST;
  logic [1:0] cmd_trans=2,M_HTRANS;
  logic [3:0] cmd_prot=3,M_HPROT;
  logic [63:0] cmd_wdata=64'h123456789abcdef0,M_HWDATA,M_HRDATA=64'h1122334455667788,rsp_rdata;
  logic [7:0] cmd_wstrb=8'ha5,M_HWSTRB;
  logic M_HWRITE,M_HMASTLOCK,M_HREADY=1,M_HRESP=0;
  logic A_rsp_valid,B_rsp_valid,A_rsp_ready=1,B_rsp_ready=1,rsp_resp;
  logic A_complete=0,B_complete=0;
  logic [2:0] gate_fault;
  logic authorized_dispatch,policy_reject,down_accept,down_complete,address_phase,data_phase,response_pending;
  ahb_lockstep_output #(.SEQ_WIDTH(8),.ENABLE_INCR8(1)) dut(.*);
  integer cycle=0,auths=0,accepts=0,completes=0,responses=0,cases=0,fd;
  string scenario="reset";
  bit pending=0;
  logic [140:0] held;
  task automatic tick;@(posedge HCLK);#2;@(negedge HCLK);endtask
  always @(posedge HCLK) begin
    cycle++;
    $fdisplay(fd,"%0d,%s,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%h,%h,%h,%h,%h",cycle,scenario,HRESETn,inhibit,authorized_dispatch,down_accept,down_complete,response_pending,A_rsp_valid,B_rsp_valid,A_complete,B_complete,M_HREADY,M_HTRANS,M_HBURST,M_HADDR,M_HWDATA,M_HWSTRB);
    $fflush(fd);
    if(!HRESETn) begin pending=0;assert(!M_HTRANS[1]) else $fatal;end
    else begin
      if(authorized_dispatch) begin assert(!inhibit&&gate_fault==0) else $fatal;auths++;end
      if(down_accept) begin assert(!pending) else $fatal;pending=1;accepts++;end
      if(down_complete) begin assert(pending) else $fatal;pending=0;completes++;end
      if(A_rsp_valid) begin assert(B_rsp_valid&&A_rsp_ready&&B_rsp_ready&&rsp_rdata==64'h1122334455667788&&!rsp_resp) else $fatal;responses++;end
    end
  end
  task automatic reset_protocol;
    HRESETn=0;match_valid=0;A_complete=0;B_complete=0;inhibit=0;M_HREADY=1;A_rsp_ready=1;B_rsp_ready=1;
    tick();HRESETn=1;tick();assert(gate_fault==0&&match_ready) else $fatal;
  endtask
  task automatic authorize(input integer beatno);
    cmd_addr=56'(beatno*8);cmd_trans=beatno==0?2:3;match_seq=8'(beatno);
    match_valid=1;tick();match_valid=0;assert(address_phase&&owner_seq==8'(beatno)) else $fatal;
  endtask
  task automatic release_owner;
    if(!response_pending) begin M_HREADY=1;while(!response_pending) tick();end
    A_rsp_ready=1;B_rsp_ready=1;tick();A_complete=1;B_complete=1;tick();A_complete=0;B_complete=0;
  endtask
  initial begin
    fd=$fopen("module-events.csv","w");
    $fdisplay(fd,"cycle,scenario,resetn,inhibit,authorization,acceptance,completion,response_pending,a_rsp,b_rsp,a_complete,b_complete,hready,htrans,hburst,haddr,hwdata,hwstrb");
    $dumpfile("f3a-output.fst");$dumpvars;
    tick();
    for(integer target=0;target<6;target++) begin
      reset_protocol();scenario=$sformatf("module_inhibit_state_%0d",target);
      if(target==5) for(integer beatno=0;beatno<7;beatno++) begin authorize(beatno);release_owner();end
      if(target!=0) begin
        authorize(target==5?7:0);
        if(target==1) M_HREADY=0;
        else begin tick();assert(data_phase) else $fatal;M_HREADY=0;end
        if(target==3||target==4) begin
          M_HREADY=1;A_rsp_ready=0;tick();assert(response_pending) else $fatal;
          if(target==4) begin A_rsp_ready=1;tick();end
        end
      end
      inhibit=1;
      held={M_HADDR,M_HWRITE,M_HSIZE,M_HBURST,M_HPROT,M_HTRANS,M_HWDATA,M_HWSTRB};
      for(integer settle=0;settle<4;settle++) begin
        tick();assert(!authorized_dispatch&&!match_ready&&dut.burst_mode.validator.fault&&(settle==0||gate_fault[0])) else $fatal(1,"inhibit bypass");
        if(target==1||target==2||target==5)
          assert({M_HADDR,M_HWRITE,M_HSIZE,M_HBURST,M_HPROT,M_HTRANS,M_HWDATA,M_HWSTRB}==held) else $fatal(1,"old owner unstable");
      end
      if(target==4) begin A_complete=1;B_complete=1;tick();A_complete=0;B_complete=0;end
      else if(target!=0) release_owner();
      match_valid=1;repeat(5) begin tick();assert(gate_fault[0]&&!authorized_dispatch&&!down_accept&&!down_complete&&!A_rsp_valid&&!B_rsp_valid) else $fatal(1,"fault reopened dispatch");end
      match_valid=0;cases++;
    end
    reset_protocol();assert(auths==accepts&&accepts==completes&&completes==responses) else $fatal(1,"module owner conservation");
    $fclose(fd);$display("F3A_MODULE_PASS cases=%0d authorized=%0d accepted=%0d completed=%0d responses=%0d",cases,auths,accepts,completes,responses);$finish;
  end
  initial begin #30000;$fatal(1,"module watchdog");end
endmodule
