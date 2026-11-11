// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Independent response consumers: B may be unready; A cannot consume early.
module output_fork_tb;
  logic HCLK=0,HRESETn=0,inhibit=0,match_valid=0,match_ready;
  always #5 HCLK=~HCLK;
  logic [7:0] match_seq=8'd9,owner_seq;
  logic [55:0] cmd_addr=56'h100,M_HADDR;
  logic cmd_write=0,cmd_lock=0;
  logic [2:0] cmd_size=3,cmd_burst=0,M_HSIZE,M_HBURST;
  logic [1:0] cmd_trans=2,M_HTRANS;
  logic [3:0] cmd_prot=3,M_HPROT;
  logic [63:0] cmd_wdata=0,M_HWDATA,M_HRDATA=64'h1122334455667788,rsp_rdata;
  logic [7:0] cmd_wstrb=0,M_HWSTRB;
  logic M_HWRITE,M_HMASTLOCK,M_HREADY=1,M_HRESP=0;
  logic A_rsp_valid,B_rsp_valid,A_rsp_ready=1,B_rsp_ready=0,rsp_resp;
  logic A_complete=0,B_complete=0;
  logic [2:0] gate_fault;
  logic authorized_dispatch,policy_reject,down_accept,down_complete,address_phase,data_phase,response_pending;
  ahb_lockstep_output #(.SEQ_WIDTH(8)) dut(.*);
  integer a_responses=0,b_responses=0;
  always @(posedge HCLK) if(HRESETn) begin
    if(A_rsp_valid&&A_rsp_ready) a_responses++;
    if(B_rsp_valid&&B_rsp_ready) b_responses++;
    assert(a_responses==b_responses) else $fatal(1,"partial fork");
  end
  task automatic tick;@(posedge HCLK);#2;@(negedge HCLK);endtask
  initial begin
    $dumpfile("output-fork.vcd");$dumpvars;
    tick();HRESETn=1;tick();
    match_valid=1;tick();match_valid=0;assert(address_phase&&owner_seq==9) else $fatal;
    tick();assert(data_phase) else $fatal;
    tick();assert(response_pending) else $fatal;
    M_HRDATA='1;
    repeat(3) begin
      tick();assert(response_pending&&!A_rsp_valid&&!B_rsp_valid&&a_responses==0&&b_responses==0&&rsp_rdata==64'h1122334455667788) else $fatal;
    end
    B_rsp_ready=1;tick();
    assert(a_responses==1&&b_responses==1&&!response_pending&&!A_rsp_valid&&!B_rsp_valid&&!match_ready) else $fatal;
    repeat(2) tick();assert(a_responses==1&&b_responses==1) else $fatal;
    A_complete=1;B_complete=1;tick();A_complete=0;B_complete=0;
    assert(match_ready&&gate_fault==0) else $fatal;
    $display("OUTPUT_FORK_TEST_PASS a_responses=%0d b_responses=%0d one_side_backpressure=3",a_responses,b_responses);
    $finish;
  end
  initial begin #2000;$fatal(1,"Fork timeout");end
endmodule
