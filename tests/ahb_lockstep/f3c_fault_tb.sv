// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Independent AHB acceptance/data ledger + byte RAM side-effect model.
module f3c_fault_tb;
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
    $fflush(trace_fd);
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

  // Runtime inputs are validated by run_f3c.py before these plusargs are used.
  integer enable_fault,target,fault_type,operation,signal_no,bit_no,delay_cycles;
  integer trigger_mode,trigger_transaction,trigger_cycle,trigger_beat;
  integer workload,save_waveform,base_a,base_b,watchdog_cycles,data_wait;
  logic [63:0] value_arg;
  integer origin_cycle=0,logical_index=0,beat_index=0,first_fault_cycle=-1;
  integer accepted_cycle[2];
  bit source_was_stalled[2];
  logic [AW+DW+SW+13:0] held_source[2];
  integer injection_fd,memory_fd,timing_fd,report_fd;
  integer applied_cycle=-1,nominal_cycle=-1,actual_delay=0,expected_reason=-1;
  integer injection_transaction=0,injection_beat=0;
  bit attempted=0,applied=0,changed=0,fail_closed=0,invalid_trans=0;
  logic [63:0] original_value=0,injected_value=0,changed_mask=0;
  request_t original_payload,injected_payload;
  integer result_code=0;
  // result: 0 no fault, 1 mismatch, 2 delay, 3 zero delay, 4 no effect,
  //         5 no eligible request, 6 inactive HTRANS, 7 trigger conflict/read lanes.
  function automatic integer sample_cycle;
    return int'($time/10)-origin_cycle;
  endfunction
  always @(posedge HCLK) begin
    for(integer side=0;side<2;side++) begin
      if(!HRESETn) source_was_stalled[side]=0;
      else begin
        if(source_was_stalled[side]) assert({addr[side],wr[side],size[side],burst[side],prot[side],trans[side],lock[side],wd[side],strb[side]}===held_source[side]) else $fatal(1,"source changed during HREADY stall");
        held_source[side]={addr[side],wr[side],size[side],burst[side],prot[side],trans[side],lock[side],wd[side],strb[side]};
        source_was_stalled[side]=!ready[side];
      end
    end
    if(HRESETn) begin
      if(ready[0]&&trans[0][1]) accepted_cycle[0]=sample_cycle();
      if(ready[1]&&trans[1][1]) accepted_cycle[1]=sample_cycle();
      if(fault_valid&&first_fault_cycle<0) first_fault_cycle=sample_cycle();
      assert(sample_cycle()<watchdog_cycles) else $fatal(1,"watchdog timeout");
    end
    $fdisplay(timing_fd,"%0t,%0d,%0d,%b,%b,%b,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%b,%b,%h,%h",
      $time,sample_cycle(),logical_index,HRESETn,ready[0],ready[1],addr[0],addr[1],wd[0],wd[1],strb[0],strb[1],
      trans[0],trans[1],wr[0],wr[1],size[0],size[1],burst[0],burst[1],prot[0],prot[1],resp[0],resp[1],rd[0],rd[1]);
  end
  task automatic snapshot(input string label_name);
    for(integer byte_no=0;byte_no<256;byte_no++) $fdisplay(memory_fd,"%s,%0d,%02h",label_name,byte_no,memory[byte_no]);
  endtask
  task automatic plan(input bit write_req,input integer ordinal);
    integer byte_address,data_tag;
    // Workload has at most 16 beats: both intermediates fit signed 32 bits.
    byte_address=(ordinal%8)*SW+(ordinal/8)*128;
    data_tag=(ordinal%8)*'h12345;
    for(integer side=0;side<2;side++) planned[side]='{
      addr:AW'(byte_address),wr:write_req,size:3'($clog2(SW)),burst:3'd5,prot:4'd3,
      trans:ordinal%8==0 ? 2'b10 : 2'b11,lock:1'b0,
      data:DW'('hfedcba9876543210)^DW'(data_tag),strb:{SW{1'b1}}};
  endtask
  task automatic inject;
    original_payload=planned[target];
    case(fault_type)
      1: begin original_value=64'(planned[target].data);expected_reason=7;end
      2: begin original_value=64'(planned[target].addr);expected_reason=0;end
      3: case(signal_no)
        0: begin original_value=64'(planned[target].wr);expected_reason=1;end
        1: begin original_value=64'(planned[target].size);expected_reason=2;end
        2: begin original_value=64'(planned[target].burst);expected_reason=3;end
        3: begin original_value=64'(planned[target].prot);expected_reason=4;end
        4: begin original_value=64'(planned[target].trans);expected_reason=5;end
        5: begin original_value=64'(planned[target].strb);expected_reason=8;end
        6: begin original_value=64'(planned[target].lock);expected_reason=6;end
        default:$fatal;
      endcase
      4: original_value=0;
      default:$fatal;
    endcase
    case(operation)
      1: injected_value=original_value^(64'd1<<bit_no);
      2: injected_value=value_arg;
      3: injected_value=original_value^value_arg;
      default:injected_value=original_value;
    endcase
    if(fault_type==4) injected_value=64'(delay_cycles);
    changed_mask=original_value^injected_value;changed=changed_mask!=0;
    if(fault_type==1) planned[target].data=DW'(injected_value);
    if(fault_type==2) planned[target].addr=AW'(injected_value);
    if(fault_type==3) case(signal_no)
      0:planned[target].wr=1'(injected_value);
      1:planned[target].size=3'(injected_value);
      2:planned[target].burst=3'(injected_value);
      3:planned[target].prot=4'(injected_value);
      4:planned[target].trans=2'(injected_value);
      5:planned[target].strb=SW'(injected_value);
      6:planned[target].lock=1'(injected_value);
      default:$fatal;
    endcase
    injected_payload=planned[target];
    invalid_trans=fault_type==3&&signal_no==4&&!planned[target].trans[1];
  endtask
  task automatic drive_source(input integer side,input integer phase_no);
    bit suppressed;
    suppressed=invalid_trans&&side==target;
    addr[side]=planned[side].addr+((phase_no>0&&!suppressed)?AW'(SW):AW'(0));
    wr[side]=planned[side].wr;size[side]=planned[side].size;
    burst[side]=planned[side].burst;prot[side]=planned[side].prot;lock[side]=planned[side].lock;
    if(phase_no==0||suppressed) trans[side]=planned[side].trans;
    else trans[side]=(phase_no<0?beat_index>1:beat_index<8)?2'b01:2'b00;
    wd[side]=phase_no>0?planned[side].data:DW'('hbad);
    strb[side]=phase_no>0?planned[side].strb:'0;
  endtask
  task automatic present(input integer da,input integer db);
    integer span;
    span=da>db?da:db;
    accepted_cycle[0]=-1;accepted_cycle[1]=-1;
    for(integer t=0;t<=span;t++) begin
      for(integer side=0;side<2;side++) begin
        drive_source(side,t==(side==0?da:db)?0:t<(side==0?da:db)?-1:1);
        if(t==(side==0?da:db)) assert(ready[side]) else $fatal(1,"address presented without empty credit");
      end
      tick();
    end
    for(integer side=0;side<2;side++) drive_source(side,1);
  endtask
  initial begin : run_workload
    integer ignored,da,db,old_auth,old_accept,old_done,old_writes,old_response;
    bit hit,write_req;
    ignored=$value$plusargs("ENABLE=%d",enable_fault);ignored=$value$plusargs("TARGET=%d",target);
    ignored=$value$plusargs("TYPE=%d",fault_type);ignored=$value$plusargs("OP=%d",operation);
    ignored=$value$plusargs("SIGNAL=%d",signal_no);ignored=$value$plusargs("BIT=%d",bit_no);
    ignored=$value$plusargs("VALUE=%h",value_arg);ignored=$value$plusargs("DELAY=%d",delay_cycles);
    ignored=$value$plusargs("TRIGGER_MODE=%d",trigger_mode);ignored=$value$plusargs("TRANSACTION=%d",trigger_transaction);
    ignored=$value$plusargs("CYCLE=%d",trigger_cycle);ignored=$value$plusargs("BEAT=%d",trigger_beat);
    ignored=$value$plusargs("WORKLOAD=%d",workload);ignored=$value$plusargs("WAVE=%d",save_waveform);
    ignored=$value$plusargs("BASE_A=%d",base_a);ignored=$value$plusargs("BASE_B=%d",base_b);
    ignored=$value$plusargs("WATCHDOG=%d",watchdog_cycles);ignored=$value$plusargs("DATA_WAIT=%d",data_wait);
    for(integer byte_no=0;byte_no<256;byte_no++) begin memory[byte_no]=8'(byte_no)^8'h5a;shadow[byte_no]=memory[byte_no];end
    for(integer side=0;side<2;side++) begin
      addr[side]=0;wd[side]=0;strb[side]=0;wr[side]=0;lock[side]=0;size[side]=0;burst[side]=0;prot[side]=0;trans[side]=0;
      occupied[side]=0;need_data[side]=0;paired[side]=0;got_rsp[side]=0;saved[side]='0;
      accepts[side]=0;completes[side]=0;cancelled[side]=0;rsp_count[side]=0;accepted_cycle[side]=-1;
    end
    trace_fd=$fopen("guard-events.csv","w");timing_fd=$fopen("source-events.csv","w");memory_fd=$fopen("memory.csv","w");injection_fd=$fopen("injection.csv","w");
    $fdisplay(trace_fd,"time_ps,cycle,case,resetn,a_accept,b_accept,a_complete,b_complete,a_rsp_capture,b_rsp_capture,a_req,b_req,pair_valid,pair_ready,match_valid,match_ready,authorized,policy_reject,down_accept,down_complete,address_phase,data_phase,response_pending,fault,a_resp,compare_reason,gate_reason,owner_seq,down_ready,down_resp,down_addr,down_wdata,down_strb,down_write,down_size,down_burst,down_trans,down_rdata");
    $fdisplay(timing_fd,"time_ps,cycle,transaction,resetn,a_ready,b_ready,a_addr,b_addr,a_wdata,b_wdata,a_strb,b_strb,a_trans,b_trans,a_write,b_write,a_size,b_size,a_burst,b_burst,a_prot,b_prot,a_resp,b_resp,a_rdata,b_rdata");
    $fdisplay(memory_fd,"snapshot,address,value");
    $fdisplay(injection_fd,"transaction,beat,target,nominal_cycle,applied_cycle,original_value,injected_value,changed_mask,original_payload,injected_payload,a_accept_cycle,b_accept_cycle,actual_delay");
    if(save_waveform!=0) begin $dumpfile("f3c-fault.fst");$dumpvars;end
    tick();tick();HRESETn=1;#1;origin_cycle=cycle;cfg_wait=data_wait;snapshot("initial");
    for(logical_index=1;logical_index<=(workload==2?16:8);logical_index++) begin
      beat_index=(logical_index-1)%8+1;write_req=workload==0||(workload==2&&logical_index<=8);
      case_name=$sformatf("transaction_%0d_beat_%0d",logical_index,beat_index);
      plan(write_req,logical_index-1);da=base_a;db=base_b;
      hit=enable_fault!=0&&!attempted&&((trigger_mode==0&&logical_index==trigger_transaction)||
        (trigger_mode==1&&cycle-origin_cycle+(target==0?da:db)==trigger_cycle));
      if(hit) begin
        attempted=1;injection_transaction=logical_index;injection_beat=beat_index;
        if((trigger_beat!=0&&trigger_beat!=beat_index)||(fault_type==3&&signal_no==4&&value_arg==1&&beat_index==1)||((fault_type==1||(fault_type==3&&signal_no==5))&&!write_req)) begin result_code=7;break;end
        nominal_cycle=cycle-origin_cycle+(target==0?da:db);inject();snapshot("before_injection");
        if(fault_type==4) begin if(target==0) da+=delay_cycles;else db+=delay_cycles;end
      end
      old_auth=auths;old_accept=down_addresses;old_done=down_completions;old_writes=writes;old_response=completes[0];
      present(da,db);
      if(hit) begin
        applied=accepted_cycle[target]>=0&&changed;
        applied_cycle=accepted_cycle[target]+(fault_type==1||signal_no==5&&fault_type==3?1:0);
        if(fault_type==4) begin actual_delay=accepted_cycle[target]-nominal_cycle;assert(actual_delay==delay_cycles) else $fatal(1,"delay measurement");end
        $fdisplay(injection_fd,"%0d,%0d,%0d,%0d,%0d,%h,%h,%h,%h,%h,%0d,%0d,%0d",logical_index,beat_index,target,nominal_cycle,applied_cycle,original_value,injected_value,changed_mask,original_payload,injected_payload,accepted_cycle[0],accepted_cycle[1],actual_delay);
        if(invalid_trans) begin
          repeat(32) tick();assert(!fault_valid&&auths==old_auth&&down_addresses==old_accept&&down_completions==old_done&&writes==old_writes&&completes[0]==old_response) else $fatal(1,"inactive HTRANS created a request");
          applied=0;applied_cycle=-1;result_code=6;break;
        end
        if(changed&&fault_type!=4) begin
          while(!fault_valid) tick();
          assert(compare_fault_reason==(11'(1)<<expected_reason)&&policy_reject==0) else $fatal(1,"wrong comparator reason");
          repeat(12) begin tick();assert(fault_valid&&!M_HTRANS[1]&&!authorized_dispatch&&!a_complete&&!b_complete&&!a_capture&&!b_capture) else $fatal(1,"fail closed bypass");end
          assert(auths==old_auth&&down_addresses==old_accept&&down_completions==old_done&&writes==old_writes&&completes[0]==old_response&&completes[1]==old_response) else $fatal(1,"unauthorized side effect");
          fail_closed=1;result_code=1;break;
        end
      end
      while(!(ready[0]&&ready[1])) begin assert(!fault_valid) else $fatal(1,"false mismatch");tick();end
      assert(pending[0]&&pending[1]) else $fatal;tick();
      assert(auths==old_auth+1&&down_addresses==old_accept+1&&down_completions==old_done+1&&completes[0]==old_response+1&&completes[1]==completes[0]) else $fatal(1,"normal conservation");
    end
    if(result_code==0&&enable_fault!=0) begin
      if(!attempted) result_code=5;
      else if(fault_type==4) result_code=delay_cycles==0?3:2;
      else result_code=4;
    end
    repeat(2) tick();snapshot("final");
    for(integer byte_no=0;byte_no<256;byte_no++) assert(memory[byte_no]==shadow[byte_no]) else $fatal(1,"memory scoreboard");
    report_fd=$fopen("tb-result.csv","w");
    $fdisplay(report_fd,"result,requested,attempted,applied,changed,detected,fail_closed,transaction,beat,applied_cycle,first_fault_cycle,expected_reason,compare_reason,gate_fault,validator_fault,auth,accepted,completed,a_completed,b_completed,writes,peer_wait,actual_delay,validator_reason");
    $fdisplay(report_fd,"%0d,%0d,%b,%b,%b,%b,%b,%0d,%0d,%0d,%0d,%0d,%h,%h,%b,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%h",result_code,enable_fault,attempted,applied,changed,fault_valid,fail_closed,injection_transaction,injection_beat,applied_cycle,first_fault_cycle,expected_reason,compare_fault_reason,gate_fault,dut.output_backend.burst_mode.validator.fault,auths,down_addresses,down_completions,completes[0],completes[1],writes,pairing_wait_cycles,actual_delay,dut.output_backend.burst_mode.validator.fault_reason);
    $fclose(report_fd);$fclose(trace_fd);$fclose(timing_fd);$fclose(memory_fd);$fclose(injection_fd);
    $display("F3C_FINISH result=%0d auth=%0d accepted=%0d completed=%0d writes=%0d",result_code,auths,down_addresses,down_completions,writes);$finish;
  end
endmodule
