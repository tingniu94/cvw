// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Independent AHB acceptance/data ledger + byte RAM side-effect model.
module burst_output_tb;
  parameter integer AW=56,DW=64,SW=DW/8;
  logic HCLK=0,HRESETn=0;
  always #5 HCLK=~HCLK;
  typedef struct packed {
    logic [AW-1:0] addr;
    logic wr;
    logic [2:0] size,burst;
    logic [3:0] prot;
    logic [1:0] trans;
    logic lock;
    logic [DW-1:0] data;
    logic [SW-1:0] strb;
  } request_t;
  request_t planned[2],saved[2];
  logic [AW-1:0] addr[2];
  logic [DW-1:0] wd[2],rd[2];
  logic [SW-1:0] strb[2];
  logic wr[2],lock[2],ready[2],resp[2],pending[2],req_valid[2];
  logic [2:0] size[2],burst[2];logic [3:0] prot[2];logic [1:0] trans[2];
  logic [AW-1:0] M_HADDR;
  logic [DW-1:0] M_HWDATA,M_HRDATA;
  logic [SW-1:0] M_HWSTRB;
  logic M_HWRITE,M_HMASTLOCK,M_HREADY,M_HRESP;
  logic [2:0] M_HSIZE,M_HBURST;
  logic [3:0] M_HPROT;logic [1:0] M_HTRANS;
  logic fault_valid;logic [10:0] compare_fault_reason;logic [2:0] gate_fault;
  logic [7:0] owner_seq;
  logic pair_valid,pair_ready,match_valid,match_ready,authorized_dispatch,policy_reject;
  logic down_accept,down_complete,address_phase,data_phase,response_pending;
  logic a_complete,b_complete,a_capture,b_capture;
  logic [63:0] pairing_wait_cycles,a_peer_wait_cycles,b_peer_wait_cycles,pair_backpressure_cycles,paired_requests;
  ahb_lockstep_guard #(.ADDR_WIDTH(AW),.DATA_WIDTH(DW),.STRB_WIDTH(SW),.SEQ_WIDTH(8),.ENABLE_INCR8(1)) dut(
    .HCLK,.HRESETn,
    .A_HADDR(addr[0]),
    .A_HWDATA(wd[0]),
    .A_HWSTRB(strb[0]),
    .A_HWRITE(wr[0]),
    .A_HMASTLOCK(lock[0]),
    .A_HSIZE(size[0]),
    .A_HBURST(burst[0]),
    .A_HPROT(prot[0]),
    .A_HTRANS(trans[0]),
    .A_HRDATA(rd[0]),
    .A_HREADY(ready[0]),
    .A_HRESP(resp[0]),
    .A_pending_valid(pending[0]),
    .A_req_valid(req_valid[0]),
    .B_HADDR(addr[1]),
    .B_HWDATA(wd[1]),
    .B_HWSTRB(strb[1]),
    .B_HWRITE(wr[1]),
    .B_HMASTLOCK(lock[1]),
    .B_HSIZE(size[1]),
    .B_HBURST(burst[1]),
    .B_HPROT(prot[1]),
    .B_HTRANS(trans[1]),
    .B_HRDATA(rd[1]),
    .B_HREADY(ready[1]),
    .B_HRESP(resp[1]),
    .B_pending_valid(pending[1]),
    .B_req_valid(req_valid[1]),
    .M_HADDR,.M_HWDATA,.M_HWSTRB,.M_HWRITE,.M_HMASTLOCK,.M_HREADY,.M_HRESP,
    .M_HSIZE,.M_HBURST,.M_HPROT,.M_HTRANS,.M_HRDATA,.fault_valid,.compare_fault_reason,.gate_fault,
    .owner_seq,.pair_valid,.pair_ready,.match_valid,.match_ready,.authorized_dispatch,.policy_reject,
    .down_accept,.down_complete,.address_phase,.data_phase,.response_pending,
    .A_complete(a_complete),.B_complete(b_complete),.A_rsp_capture(a_capture),.B_rsp_capture(b_capture),
    .pairing_wait_cycles,.a_peer_wait_cycles,.b_peer_wait_cycles,.pair_backpressure_cycles,.paired_requests
  );
  logic [7:0] memory[256],shadow[256];
  bit slave_pending=0,slave_write=0,slave_error=0,error_first_done=0;
  logic [AW-1:0] slave_addr=0;
  integer wait_left=0,cfg_wait=0;
  bit cfg_error=0,force_address_stall=0,force_idle_stall=0;
  function automatic logic [DW-1:0] word_at(input logic [AW-1:0] a,input bit reference_memory);
    logic [DW-1:0] value;
    integer base;
    base=int'(a[7:0]) & ~(SW-1);value='0;
    for(int lane=0;lane<SW;lane++) value[lane*8+:8]=reference_memory ? shadow[base+lane] : memory[base+lane];
    return value;
  endfunction
  always_comb begin
    M_HREADY=HRESETn && (slave_pending ? (wait_left==0 && (!slave_error||error_first_done)) : !(force_idle_stall||(force_address_stall&&M_HTRANS[1])));
    M_HRESP=HRESETn&&slave_pending&&slave_error&&(wait_left==0);
    M_HRDATA=slave_pending ? word_at(slave_addr,0) : DW'('hbad);
  end
  bit occupied[2],need_data[2],paired[2],authorized=0,issued=0,done=0,got_rsp[2];
  logic [DW-1:0] expected_data;
  bit expected_error;
  integer accepts[2],completes[2],cancelled[2],rsp_count[2];
  integer pairs=0,auths=0,down_addresses=0,down_completions=0,reads=0,writes=0,errors=0;
  integer cycle=0,trace_fd,checks=0;
  string case_name="reset";
  logic [AW+DW+SW+14-1:0] stalled_master;
  bit was_stalled=0;

  always @(posedge HCLK) begin : oracle
    logic [AW+DW+SW+14-1:0] master_now;
    master_now={M_HADDR,M_HWRITE,M_HSIZE,M_HBURST,M_HPROT,M_HTRANS,M_HMASTLOCK,M_HWDATA,M_HWSTRB};
    $fdisplay(trace_fd,"%0t,%0d,%s,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%h,%h,%0d,%b,%b,%h,%h,%h,%b,%0d,%0d,%b,%h",
      $time,cycle,case_name,HRESETn,ready[0]&&trans[0][1],ready[1]&&trans[1][1],a_complete,b_complete,
      a_capture,b_capture,req_valid[0],req_valid[1],pair_valid,pair_ready,match_valid,match_ready,
      authorized_dispatch,policy_reject,down_accept,down_complete,address_phase,data_phase,response_pending,
      fault_valid,resp[0],compare_fault_reason,gate_fault,owner_seq,M_HREADY,M_HRESP,M_HADDR,M_HWDATA,M_HWSTRB,M_HWRITE,M_HSIZE,M_HBURST,M_HTRANS,M_HRDATA);
    cycle++;
    if(!HRESETn) begin
      for(int side=0;side<2;side++) begin
        if(occupied[side]) cancelled[side]++;
        occupied[side]=0;need_data[side]=0;paired[side]=0;got_rsp[side]=0;saved[side]='0;
      end
      slave_pending<=0;wait_left<=0;error_first_done<=0;
      authorized=0;issued=0;done=0;was_stalled=0;
      assert(!M_HTRANS[1]&&!a_capture&&!b_capture&&!a_complete&&!b_complete) else $fatal;
    end else begin
      if(M_HTRANS[1]) assert(authorized&&!fault_valid) else $fatal(1,"valid address without authorization");
      if(was_stalled) assert(master_now===stalled_master) else $fatal(1,"AHB payload changed across stalled edge case=%s",case_name);
      was_stalled=!M_HREADY;stalled_master=master_now;
      assert(a_complete==b_complete&&a_capture==b_capture) else $fatal(1,"A/B response timing differs");
      if(pair_valid&&pair_ready) begin
        assert(occupied[0]&&occupied[1]&&!need_data[0]&&!need_data[1]&&!paired[0]&&!paired[1]) else $fatal;
        paired[0]=1;paired[1]=1;pairs++;
      end
      if(authorized_dispatch) begin
        assert(paired[0]&&paired[1]&&!authorized&&!fault_valid&&saved[0]===saved[1]) else $fatal(1,"unauthorized/mismatched dispatch");
        authorized=1;auths++;
      end
      if(down_accept) begin
        assert(M_HTRANS[1]&&M_HREADY&&!slave_pending&&authorized&&!issued&&!fault_valid) else $fatal(1,"duplicate/unauthorized downstream address");
        assert({M_HADDR,M_HWRITE,M_HSIZE,M_HBURST,M_HPROT,M_HTRANS,M_HMASTLOCK}===
          {saved[0].addr,saved[0].wr,saved[0].size,saved[0].burst,saved[0].prot,saved[0].trans,saved[0].lock}) else $fatal(1,"downstream metadata differs");
        issued=1;down_addresses++;
        slave_pending<=1;slave_addr<=M_HADDR;slave_write<=M_HWRITE;
        slave_error<=cfg_error;wait_left<=cfg_wait;error_first_done<=0;
      end
      if(slave_pending) begin
        assert(issued&&data_phase&&!M_HTRANS[1]) else $fatal(1,"data phase lost or duplicate address");
        if(slave_write) assert(M_HWDATA==saved[0].data&&M_HWSTRB==saved[0].strb) else $fatal(1,"write data/strobe differs");
        if(wait_left>0) wait_left<=wait_left-1;
        else if(slave_error&&!error_first_done) error_first_done<=1;
      end
      if(down_complete) begin
        assert(slave_pending&&issued&&!done) else $fatal(1,"false downstream completion");
        done=1;down_completions++;slave_pending<=0;
        expected_data=word_at(slave_addr,1);expected_error=slave_error;
        assert(M_HRDATA==expected_data&&M_HRESP==expected_error) else $fatal;
        if(slave_error) errors++;
        else if(slave_write) begin
          integer base;
          base=int'(slave_addr[7:0]) & ~(SW-1);
          for(int lane=0;lane<SW;lane++) if(M_HWSTRB[lane]) begin
            memory[base+lane]<=M_HWDATA[lane*8+:8];shadow[base+lane]=saved[0].data[lane*8+:8];
          end
          writes++;
        end else reads++;
      end
      if(a_capture) begin
        assert(done&&authorized&&!got_rsp[0]&&!got_rsp[1]) else $fatal(1,"response before completion or duplicate fork");
        got_rsp[0]=1;got_rsp[1]=1;rsp_count[0]++;rsp_count[1]++;
      end
      for(int side=0;side<2;side++) begin
        if(need_data[side]) begin saved[side].data=wd[side];saved[side].strb=strb[side];need_data[side]=0;end
        if(side==0 ? a_complete : b_complete) begin
          assert(occupied[side]&&got_rsp[side]&&rd[side]==expected_data&&resp[side]==expected_error) else $fatal(1,"wrong/false A/B response");
          completes[side]++;occupied[side]=0;paired[side]=0;got_rsp[side]=0;
        end
      end
      if(a_complete&&b_complete) begin authorized=0;issued=0;done=0;end
      for(int side=0;side<2;side++) if(ready[side]&&trans[side][1]) begin
        assert(!occupied[side]) else $fatal(1,"upstream pending overwritten");
        saved[side]='{addr:addr[side],wr:wr[side],size:size[side],burst:burst[side],prot:prot[side],trans:trans[side],lock:lock[side],data:DW'(0),strb:SW'(0)};
        occupied[side]=1;need_data[side]=wr[side];accepts[side]++;
      end
      checks++;
    end
  end

  task automatic tick;@(posedge HCLK);#2;@(negedge HCLK);endtask
  task automatic default_request(input bit write_req,input logic [AW-1:0] address);
    for(int side=0;side<2;side++) begin
      planned[side]='{addr:address,wr:write_req,size:3'($clog2(SW)),burst:3'd0,prot:4'd3,
        trans:2'b10,lock:1'b0,data:DW'('h89abcdef01234567),strb:{SW{1'b1}}};
    end
  endtask
  task automatic reset_all;
    HRESETn=0;tick();
    assert(!fault_valid&&!M_HTRANS[1]&&!pending[0]&&!pending[1]) else $fatal;
    for(int side=0;side<2;side++) trans[side]=0;
    force_address_stall=0;force_idle_stall=0;cfg_error=0;cfg_wait=0;
    HRESETn=1;tick();assert(ready[0]&&ready[1]&&!fault_valid) else $fatal;
  endtask
  task automatic launch(input integer skew);
    integer ta,tb,span;
    ta=skew<0 ? -skew : 0;tb=skew>0 ? skew : 0;span=ta>tb ? ta : tb;
    for(int t=0;t<=span;t++) begin
      for(int side=0;side<2;side++) begin
        addr[side]=planned[side].addr;wr[side]=planned[side].wr;size[side]=planned[side].size;
        burst[side]=planned[side].burst;prot[side]=planned[side].prot;lock[side]=planned[side].lock;
        trans[side]=t==(side==0 ? ta : tb) ? planned[side].trans : 2'b00;
        wd[side]=t>(side==0 ? ta : tb) ? planned[side].data : DW'('hbad);
        strb[side]=t>(side==0 ? ta : tb) ? planned[side].strb : '0;
        if(t==(side==0 ? ta : tb)) assert(ready[side]) else $fatal;
      end
      tick();
    end
    for(int side=0;side<2;side++) begin trans[side]=0;wd[side]=planned[side].data;strb[side]=planned[side].strb;end
  endtask
  task automatic wait_release;
    while(!(ready[0]&&ready[1])) tick();
    assert(pending[0]&&pending[1]&&rd[0]==rd[1]&&resp[0]==resp[1]) else $fatal;
  endtask
  task automatic transaction(input string name,input integer skew,input integer address_wait,input integer data_wait,input bit error_reply);
    integer old_addresses,old_completes;
    case_name=name;old_addresses=down_addresses;old_completes=completes[0];
    cfg_wait=data_wait;cfg_error=error_reply;force_address_stall=address_wait>0;
    launch(skew);
    if(force_idle_stall) begin
      repeat(6) tick();
      assert(match_valid&&!authorized_dispatch&&!address_phase&&M_HTRANS==1)
        else $fatal(1,"BUSY credit backpressure");
      force_idle_stall=0;
    end
    while(!address_phase) begin assert(!fault_valid) else $fatal;tick();end
    repeat(address_wait) tick();force_address_stall=0;
    // First edge after release of the address stall accepts the address.
    tick();assert(down_addresses==old_addresses+1) else $fatal;
    wait_release();
    if(error_reply) for(int side=0;side<2;side++) begin
      trans[side]=2;addr[side]=planned[side].addr+AW'(SW);wr[side]=0;
    end
    tick();for(int side=0;side<2;side++) trans[side]=0;
    assert(completes[0]==old_completes+1&&completes[1]==completes[0]) else $fatal;
    if(error_reply) begin
      repeat(2) tick();
      assert(fault_valid&&gate_fault[1]&&pending[0]&&pending[1]&&!pair_ready&&!M_HTRANS[1]) else $fatal;
      reset_all();
    end
    else assert(!fault_valid&&!pending[0]&&!pending[1]) else $fatal;
  endtask
  task automatic rejection(input string name,input bit comparator_reject);
    integer old_addresses,old_auth,old_complete,old_writes;
    case_name=name;old_addresses=down_addresses;old_auth=auths;old_complete=completes[0];old_writes=writes;
    launch(0);while(!fault_valid) tick();
    if(comparator_reject) assert(compare_fault_reason!=0&&gate_fault==0) else $fatal;
    else assert(gate_fault[0]) else $fatal;
    for(int side=0;side<2;side++) begin trans[side]=2;addr[side]=AW'('hdead);end
    repeat(4) tick();
    assert(!M_HTRANS[1]&&down_addresses==old_addresses&&auths==old_auth&&completes[0]==old_complete&&writes==old_writes&&!ready[0]&&!ready[1]) else $fatal(1,"fault leaked side effect/success");
    reset_all();
  endtask


  integer burst_remaining=0,burst_addresses=0,busy_cycles=0,last_data_stalls=0,up_overlap=0;
  logic [AW-1:0] next_burst_addr;
  logic burst_direction;
  logic [2:0] burst_size;
  logic [3:0] burst_prot;
  always @(posedge HCLK) begin
    if(!HRESETn) begin burst_remaining=0;next_burst_addr=0;end
    else begin
      if(M_HTRANS==1) begin
        assert(burst_remaining>0 && M_HBURST==5 && M_HADDR==next_burst_addr &&
          M_HWRITE==burst_direction && M_HSIZE==burst_size && M_HPROT==burst_prot)
          else $fatal(1,"invalid BUSY control");
        busy_cycles++;
      end
      if(M_HTRANS==0) assert(burst_remaining==0) else $fatal(1,"early IDLE in fixed burst");
      if(M_HREADY&&M_HTRANS[1]) begin
        if(M_HTRANS==2) begin
          assert(burst_remaining==0) else $fatal(1,"early NONSEQ");
          if(M_HBURST==5) begin
            burst_remaining=8;next_burst_addr=M_HADDR;
            burst_direction=M_HWRITE;burst_size=M_HSIZE;burst_prot=M_HPROT;
          end else assert(M_HBURST==0) else $fatal;
        end else assert(burst_remaining>0 && M_HBURST==5) else $fatal(1,"unexpected SEQ");
        if(burst_remaining>0) begin
          assert(M_HADDR==next_burst_addr&&M_HWRITE==burst_direction&&
            M_HSIZE==burst_size&&M_HPROT==burst_prot) else $fatal;
          burst_remaining--;next_burst_addr+=AW'(1)<<burst_size;burst_addresses++;
        end
      end
      if(slave_pending && M_HBURST==5 && burst_remaining==0 && !M_HREADY) begin
        assert(M_HTRANS==0 && dut.output_backend.burst_mode.validator.burst_active)
          else $fatal(1,"last data prematurely ended");
        last_data_stalls++;
      end
      if(a_complete && ready[0] && trans[0][1]) up_overlap++;
    end
  end
  task automatic plan_beat(input bit write_req,input integer base,input integer beatno,input bit isburst);
    default_request(write_req,AW'(base+beatno*SW));
    for(integer side=0;side<2;side++) begin
      planned[side].burst=isburst ? 3'd5 : 3'd0;
      planned[side].trans=isburst && beatno>0 ? 2'b11 : 2'b10;
      planned[side].data=DW'('hfedcba9876543210)^DW'(beatno*'h12345);
      planned[side].strb=beatno%2==0 ? {SW{1'b1}} : (SW'(1)<<(beatno%SW));
    end
  endtask
  initial begin
    for(int i=0;i<256;i++) begin memory[i]=8'(i)^8'h5a;shadow[i]=8'(i)^8'h5a;end
    for(int side=0;side<2;side++) begin
      addr[side]=0;wd[side]=0;strb[side]=0;wr[side]=0;lock[side]=0;size[side]=0;burst[side]=0;prot[side]=0;trans[side]=0;
      occupied[side]=0;need_data[side]=0;paired[side]=0;got_rsp[side]=0;saved[side]='0;
      accepts[side]=0;completes[side]=0;cancelled[side]=0;rsp_count[side]=0;
    end
    trace_fd=$fopen("guard-events.csv","w");assert(trace_fd!=0) else $fatal;
    $fdisplay(trace_fd,"time_ps,cycle,case,resetn,a_accept,b_accept,a_complete,b_complete,a_rsp_capture,b_rsp_capture,a_req,b_req,pair_valid,pair_ready,match_valid,match_ready,authorized,policy_reject,down_accept,down_complete,address_phase,data_phase,response_pending,fault,a_resp,compare_reason,gate_reason,owner_seq,down_ready,down_resp,down_addr,down_wdata,down_strb,down_write,down_size,down_burst,down_trans,down_rdata");
    $dumpfile("burst-output.fst");$dumpvars;
    tick();reset_all();
    // Continuous context lifetime across independently completed beats;
    // each burst immediately followed by another burst or a SINGLE.
    for(integer groupno=0;groupno<4;groupno++) begin
      for(integer beatno=0;beatno<8;beatno++) begin
        plan_beat(groupno%2==0,256+(groupno%2)*128,beatno,1);
        force_idle_stall=(groupno==2 && beatno==3);
        if(groupno==3 && beatno==7) begin
          case_name="burst_tail_to_single_overlap";cfg_wait=4;force_address_stall=1;
          launch(0);while(!address_phase) tick();repeat(2) tick();force_address_stall=0;
          tick();wait_release();
          // Final downstream Data is already buffered; preserve its response
          // through the upstream completion edge while accepting next NONSEQ.
          plan_beat(0,64,0,0);
          for(integer side=0;side<2;side++) begin
            addr[side]=planned[side].addr;wr[side]=0;size[side]=planned[side].size;
            burst[side]=0;prot[side]=3;lock[side]=0;trans[side]=2;
          end
          tick();for(integer side=0;side<2;side++) trans[side]=0;
          wait_release();tick();
        end else transaction($sformatf("incr8_%0d_beat_%0d",groupno,beatno),
          (beatno%7)-3,groupno<2 ? 0 : beatno%3+1,groupno<2 ? 0 : beatno%4+1,0);
        assert(down_addresses==down_completions&&down_completions==completes[0]&&
          completes[0]==completes[1]&&auths==down_addresses&&pairs==auths) else $fatal(1,"per-beat conservation");
      end
    end
    plan_beat(1,72,0,0);transaction("single_write",2,1,2,0);
    // Old upstream data completion and new address acceptance on one edge.
    plan_beat(1,80,0,0);case_name="upstream_overlap_old_write";cfg_wait=2;launch(0);wait_release();
    plan_beat(0,88,0,0);
    for(integer side=0;side<2;side++) begin
      addr[side]=planned[side].addr;wr[side]=planned[side].wr;size[side]=planned[side].size;
      burst[side]=0;prot[side]=3;lock[side]=0;trans[side]=2;
    end
    tick();for(integer side=0;side<2;side++) trans[side]=0;
    wait_release();tick();repeat(3) tick();
    assert(up_overlap==2&&auths==36&&down_addresses==36&&down_completions==36&&
      completes[0]==36&&completes[1]==36&&burst_addresses==32&&last_data_stalls>0&&busy_cycles>0)
      else $fatal(1,"normal ledger mismatch %0d",down_addresses);
    // Unmatched request: peer absent, never authorize or complete.
    reset_all();case_name="unmatched";default_request(1,AW'(96));
    addr[0]=planned[0].addr;wr[0]=1;size[0]=planned[0].size;burst[0]=0;prot[0]=3;trans[0]=2;
    tick();trans[0]=0;wd[0]=planned[0].data;strb[0]=planned[0].strb;
    repeat(6) tick();assert(auths==36&&down_addresses==36&&!M_HTRANS[1]&&!fault_valid) else $fatal;
    reset_all();
    default_request(1,AW'(96));planned[1].addr=AW'(104);rejection("mismatch_initial",1);
    default_request(1,AW'(1024-SW));planned[0].burst=5;planned[1].burst=5;
    rejection("validator_boundary",0);
    // Mid-burst validator rejection: keep BUSY, never dispatch illegal beat.
    plan_beat(1,256,0,1);transaction("partial_prefix",0,0,1,0);
    plan_beat(1,256,2,1);case_name="invalid_second_address";launch(0);
    while(!fault_valid) tick();repeat(5) tick();
    assert(M_HTRANS==1&&down_addresses==37&&down_completions==37&&completes[0]==37&&
      dut.output_backend.burst_mode.validator.burst_active&&gate_fault[0]) else $fatal(1,"fail-closed prefix");
    reset_all();repeat(3) tick();
    $fclose(trace_fd);
    $display("F2_PASS normal_beats=36 bursts=4 burst_beats=32 prefix_beats=1 busy_cycles=%0d final_data_stalls=%0d upstream_overlap=%0d",busy_cycles,last_data_stalls,up_overlap);
    $finish;
  end
  initial begin #200000; $fatal(1,"watchdog timeout");end
endmodule
