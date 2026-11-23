// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Independent AHB acceptance/data ledger + byte RAM side-effect model.
module controller_gate_tb;
  import cvw::*;
  `include "config.vh"
  `include "parameter-defs.vh"
  localparam integer AW=P.PA_BITS,DW=P.AHBW,SW=DW/8;
  parameter bit RO=0;
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
  request_t saved[2];
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
  logic [31:0] owner_seq;
  logic pair_valid,pair_ready,match_valid,match_ready,authorized_dispatch,policy_reject;
  logic down_accept,down_complete,address_phase,data_phase,response_pending;
  logic a_complete,b_complete,a_capture,b_capture;
  logic [63:0] pairing_wait_cycles,a_peer_wait_cycles,b_peer_wait_cycles,pair_backpressure_cycles,paired_requests;
  ahb_lockstep_guard #(.ADDR_WIDTH(AW),.DATA_WIDTH(DW),.STRB_WIDTH(SW),.SEQ_WIDTH(32),.ENABLE_INCR8(1)) dut(
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

  logic [1:0] cache_rw[2],bus_rw[2];
  logic cache_mode[2],ack[2],bus_stall[2],committed[2];
  logic [AW-1:0] base[2];
  logic [2:0] beat[2],single_size=3;
  logic [511:0] fetch[2];
  logic [P.LLEN-1:0] cache_word[2],single_word;
  function automatic logic [63:0] pattern(input logic [AW-1:0] a,input logic [2:0] b);
    return 64'h1032547698badcfe ^ (64'(a)<<16) ^ (64'(b)*64'h01030507090b0d0f);
  endfunction
  for(genvar g=0;g<2;g++) begin: original
    assign cache_word[g]=pattern(base[g],beat[g]);
    assign lock[g]=0;assign prot[g]=3;
    ahbcacheinterface #(.P(P),.BEATSPERLINE(8),.AHBWLOGBWPL(3),.LINELEN(512),
      .LLENPOVERAHBW(P.LLEN/P.AHBW),.READ_ONLY_CACHE(RO)) controller(
      .HCLK,.HRESETn,.HREADY(ready[g]),.HTRANS(trans[g]),.HWRITE(wr[g]),
      .HSIZE(size[g]),.HBURST(burst[g]),.HRDATA(rd[g]),.HADDR(addr[g]),
      .HWDATA(wd[g]),.HWSTRB(strb[g]),.CacheBusAdr(base[g]),
      .CacheReadDataWordM(cache_word[g]),.CacheableOrFlushCacheM(cache_mode[g]),
      .Cacheable(cache_mode[g]),.CacheBusRW(cache_rw[g]),.CacheBusAck(ack[g]),
      .FetchBuffer(fetch[g]),.BeatCount(beat[g]),.SelBusBeat(),.PAdr(base[g]),
      .WriteDataM(single_word),.BusRW(bus_rw[g]),.BusAtomic(1'b0),.Size(single_size),
      .BusCMOZero(1'b0),.Stall(1'b0),.Flush(1'b0),.BusStall(bus_stall[g]),
      .BusCommitted(committed[g]));
  end
  logic [7:0] memory[4096],shadow[4096];
  bit occupied[2],need_data[2],paired[2],got_response[2],cache_req[2];
  logic [63:0] expected_write[2],expected_read,read_words[2][8];
  logic [2:0] saved_beat[2];
  integer accepted[2],completed[2],acks[2],pairs=0,auths=0,downs=0,dones=0;
  integer writes=0,reads=0,cycle=0,event_fd,case_fd,cases=0,progress=0;
  integer data_wait=0,address_wait=0;
  bit varied_wait=0,address_seen=0,slave_pending=0,slave_write=0;
  bit authorized=0,issued=0,done=0;
  logic [AW-1:0] slave_addr;
  logic [63:0] slave_data;
  logic [7:0] slave_strb;
  logic [AW+DW+SW+13:0] old_master;
  logic [63:0] old_wdata[2];logic [7:0] old_strb[2];
  bit stalled=0,up_stalled[2];
  string case_name="reset";
  function automatic logic [63:0] word_at(input logic [AW-1:0] a,input bit reference_mem);
    logic [63:0] value;integer off;
    off=int'(a[11:0]) & ~7;value=0;
    for(integer j=0;j<8;j++) value[8*j+:8]=reference_mem?shadow[off+j]:memory[off+j];
    return value;
  endfunction
  assign M_HREADY=HRESETn && (slave_pending ? data_wait==0 : !(address_phase&&address_wait>0));
  assign M_HRESP=0;
  assign M_HRDATA=slave_pending ? word_at(slave_addr,0) : 64'hbad;
  // Determine Address wait before the next rising acceptance edge.
  always @(negedge HCLK) begin
    if(!HRESETn || !address_phase) begin address_seen=0;address_wait=0;end
    else if(!address_seen) begin address_seen=1;address_wait=varied_wait ? (downs%3)+1 : 0;end
    else if(address_wait>0) address_wait--;
  end
  always @(posedge HCLK) begin: scoreboard
    logic [AW+DW+SW+13:0] master_now;
    master_now={M_HADDR,M_HWRITE,M_HSIZE,M_HBURST,M_HPROT,M_HTRANS,M_HMASTLOCK,M_HWDATA,M_HWSTRB};
    $fdisplay(event_fd,"%0t,%0d,%s,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%h,%h,%h,%h,%b,%0d,%0d,%b,%b,%b,%0d,%0d,%0d,%0d,%0d,%0d,%b,%b,%b,%h,%h,%h,%h,%h,%h,%0d,%b,%b",
      $time,cycle,case_name,HRESETn,ready[0]&&trans[0][1],ready[1]&&trans[1][1],a_complete,b_complete,
      a_capture,b_capture,pair_valid,pair_ready,match_valid,match_ready,authorized_dispatch,
      down_accept,down_complete,address_phase,data_phase,M_HREADY,M_HADDR,M_HWDATA,M_HWSTRB,M_HRDATA,
      M_HRESP,M_HSIZE,M_HBURST,M_HTRANS,ack[0],ack[1],beat[0],beat[1],accepted[0],accepted[1],completed[0],completed[1],
      ready[0],ready[1],fault_valid,addr[0],addr[1],wd[0],wd[1],strb[0],strb[1],owner_seq,
      dut.ingress_pair.ingress_a.req_valid,dut.ingress_pair.ingress_b.req_valid);
    cycle++;
    if(HRESETn) begin
      assert(!fault_valid&&!policy_reject&&!resp[0]&&!resp[1]) else $fatal(1,"unexpected fault %h %h",compare_fault_reason,gate_fault);
      if(stalled) assert(master_now==old_master) else $fatal(1,"downstream stability");
      stalled=!M_HREADY;old_master=master_now;
      if(M_HTRANS[1]) assert(authorized) else $fatal(1,"address before MATCH");
      assert(a_complete==b_complete&&a_capture==b_capture) else $fatal(1,"response timing skew");
      if(pair_valid&&pair_ready) begin
        assert(occupied[0]&&occupied[1]&&!need_data[0]&&!need_data[1]&&!paired[0]&&!paired[1]) else $fatal;
        assert(saved[0]==saved[1]) else $fatal(1,"controller false pairing");
        paired[0]=1;paired[1]=1;pairs++;
      end
      if(authorized_dispatch) begin
        assert(paired[0]&&paired[1]&&!authorized) else $fatal;
        authorized=1;auths++;
      end
      if(down_accept) begin
        assert(authorized&&!issued&&!slave_pending&&owner_seq==32'(downs)) else $fatal(1,"duplicate owner");
        assert({M_HADDR,M_HWRITE,M_HSIZE,M_HBURST,M_HPROT,M_HTRANS,M_HMASTLOCK}==
          {saved[0].addr,saved[0].wr,saved[0].size,saved[0].burst,saved[0].prot,saved[0].trans,saved[0].lock}) else $fatal(1,"address metadata");
        slave_pending<=1;slave_addr<=M_HADDR;slave_write<=M_HWRITE;
        slave_data<=expected_write[0];slave_strb<=saved[0].strb;
        data_wait<=varied_wait ? (downs%4)+1 : 0;issued=1;downs++;progress=cycle;
      end
      if(slave_pending) begin
        assert(data_phase&&!M_HTRANS[1]) else $fatal;
        if(slave_write) assert(M_HWDATA==slave_data&&M_HWSTRB==slave_strb) else $fatal(1,"write data/address mismatch");
        if(data_wait>0) data_wait<=data_wait-1;
      end
      if(down_complete) begin
        integer off;
        assert(slave_pending&&issued&&!done) else $fatal(1,"unowned completion");
        done=1;dones++;slave_pending<=0;expected_read=word_at(slave_addr,1);
        assert(M_HRDATA==expected_read) else $fatal(1,"readback shadow");
        off=int'(slave_addr[11:0]) & ~7;
        if(slave_write) begin
          for(integer j=0;j<8;j++) if(M_HWSTRB[j]) begin
            memory[off+j]<=M_HWDATA[8*j+:8];shadow[off+j]=slave_data[8*j+:8];
          end
          writes++;
        end else reads++;
      end
      if(a_capture) begin
        assert(done&&!got_response[0]&&!got_response[1]) else $fatal;
        got_response[0]=1;got_response[1]=1;
      end
      for(integer side=0;side<2;side++) begin
        // The original write register is updated on address acceptance,
        // then captured by Ingress at THIS next rising edge, even HREADY=0.
        if(need_data[side]) begin
          assert(wd[side]==expected_write[side]) else $fatal(1,"original wdreg wrong beat side=%0d",side);
          saved[side].data=wd[side];saved[side].strb=strb[side];need_data[side]=0;
          if(cache_req[side]) assert(strb[side]==8'hff) else $fatal;
          else assert(strb[side]==(8'h01<<saved[side].addr[2:0])) else $fatal(1,"byte mask");
        end
        if(up_stalled[side]) assert(wd[side]==old_wdata[side]&&strb[side]==old_strb[side]) else $fatal(1,"controller write stability");
        up_stalled[side]=!ready[side];old_wdata[side]=wd[side];old_strb[side]=strb[side];
        if(ack[side]) begin
          assert((side==0?a_complete:b_complete)&&cache_req[side]&&saved_beat[side]==7&&done)
            else $fatal(1,"early CacheBusAck side=%0d",side);
          acks[side]++;
        end
        if(side==0?a_complete:b_complete) begin
          assert(occupied[side]&&got_response[side]&&rd[side]==expected_read&&!resp[side]) else $fatal(1,"wrong response");
          if(cache_req[side]&&!saved[side].wr) read_words[side][saved_beat[side]]=expected_read;
          completed[side]++;occupied[side]=0;paired[side]=0;got_response[side]=0;
        end
      end
      if(a_complete&&b_complete) begin authorized=0;issued=0;done=0;end
      for(integer side=0;side<2;side++) if(ready[side]&&trans[side][1]) begin
        assert(!occupied[side]) else $fatal(1,"slot overwritten");
        saved[side]='{addr:addr[side],wr:wr[side],size:size[side],burst:burst[side],prot:prot[side],trans:trans[side],lock:lock[side],data:64'd0,strb:8'd0};
        cache_req[side]=cache_mode[side];saved_beat[side]=beat[side];
        if(cache_mode[side]) begin
          assert(burst[side]==5&&size[side]==3&&addr[side]==base[side]+AW'(8*int'(beat[side]))&&
            trans[side]==(beat[side]==0?2'b10:2'b11)) else $fatal(1,"original INCR8 sequence");
        end else assert(burst[side]==0&&trans[side]==2) else $fatal;
        expected_write[side]=cache_mode[side]?pattern(base[side],beat[side]):single_word;
        occupied[side]=1;need_data[side]=wr[side];accepted[side]++;
      end
      assert(cycle-progress<500) else $fatal(1,"progress watchdog");
    end
  end
  task automatic tick; @(posedge HCLK);#2;@(negedge HCLK);endtask
  task automatic check_fetch;
    for(integer side=0;side<2;side++) for(integer j=0;j<8;j++)
      assert(fetch[side][64*j+:64]==read_words[side][j]) else $fatal(1,"FetchBuffer order side=%0d beat=%0d",side,j);
  endtask
  task automatic line_request(input bit write_req,input integer address,input integer skew,input bit waits);
    integer aa,ab,ca,cb,start,old_down;
    case_name=$sformatf("%s_%0d_skew_%0d_wait_%0d",write_req?"writeback":"refill",address,skew,waits);
    aa=accepted[0];ab=accepted[1];ca=acks[0];cb=acks[1];start=cycle;old_down=downs;varied_wait=waits;
    for(integer side=0;side<2;side++) begin cache_mode[side]=1;base[side]=AW'(address);cache_rw[side]=0;end
    if(skew>=0) cache_rw[0]=write_req?1:2;else cache_rw[1]=write_req?1:2;
    repeat(skew<0?-skew:skew) tick();
    cache_rw[skew>=0?1:0]=write_req?1:2;
    while(acks[0]==ca||acks[1]==cb) begin
      if(accepted[0]>aa) cache_rw[0]=0;
      if(accepted[1]>ab) cache_rw[1]=0;
      tick();
    end
    if(!write_req) check_fetch();
    assert(accepted[0]-aa==8&&accepted[1]-ab==8&&downs-old_down==8&&dones==downs) else $fatal;
    cases++;$fdisplay(case_fd,"%s,%0d,%0d,%0d,%0d",case_name,start,cycle,cycle-start,downs-old_down);
    tick();
  endtask
  task automatic chain(input bit first_write,input bit second_write,input integer address);
    integer aa,ab,ca,cb,start,old_down;
    case_name=$sformatf("chain_%0d_%0d",first_write,second_write);
    aa=accepted[0];ab=accepted[1];ca=acks[0];cb=acks[1];start=cycle;old_down=downs;varied_wait=1;
    for(integer side=0;side<2;side++) begin cache_mode[side]=1;base[side]=AW'(address);cache_rw[side]=first_write?1:2;end
    while(accepted[0]<aa+8||accepted[1]<ab+8) begin
      if(accepted[0]>aa) cache_rw[0]=0;
      if(accepted[1]>ab) cache_rw[1]=0;
      tick();
    end
    // Last data remains pending. Present next cache-side command; the ORIGINAL
    // FSM emits NONSEQ on the final completion edge, not a TB AHB override.
    assert(acks[0]==ca&&acks[1]==cb) else $fatal;
    for(integer side=0;side<2;side++) begin base[side]=AW'(address+128);cache_rw[side]=second_write?1:2;end
    while(acks[0]<ca+2||acks[1]<cb+2) begin
      if(accepted[0]>aa+8) cache_rw[0]=0;
      if(accepted[1]>ab+8) cache_rw[1]=0;
      tick();
      if(acks[0]==ca+1&&!first_write) check_fetch();
    end
    if(!second_write) check_fetch();
    assert(accepted[0]-aa==16&&accepted[1]-ab==16&&downs-old_down==16&&dones==downs) else $fatal;
    cases++;$fdisplay(case_fd,"%s,%0d,%0d,%0d,%0d",case_name,start,cycle,cycle-start,downs-old_down);tick();
  endtask
  task automatic single_request(input bit write_req,input integer address);
    integer ca,cb,start,old_down;
    case_name=$sformatf("single_%0d_lane_%0d",write_req,address%8);
    ca=completed[0];cb=completed[1];start=cycle;old_down=downs;varied_wait=1;
    single_size=write_req?0:3;single_word=64'hf1e2d3c4b5a69788;
    for(integer side=0;side<2;side++) begin cache_mode[side]=0;base[side]=AW'(address);bus_rw[side]=write_req?1:2;end
    while(completed[0]==ca||completed[1]==cb) tick();
    if(!write_req) for(integer side=0;side<2;side++) assert(fetch[side][63:0]==expected_read) else $fatal;
    for(integer side=0;side<2;side++) bus_rw[side]=0;
    assert(downs-old_down==1&&dones==downs) else $fatal;
    cases++;$fdisplay(case_fd,"%s,%0d,%0d,%0d,%0d",case_name,start,cycle,cycle-start,downs-old_down);repeat(3) tick();
  endtask
  initial begin
    assert(P.BURST_EN&&P.AHBW==64&&P.LLEN==64&&P.DCACHE_LINELENINBITS==512&&P.ICACHE_LINELENINBITS==512) else $fatal;
    for(integer i=0;i<4096;i++) begin memory[i]=8'(i*7)^8'h5a;shadow[i]=8'(i*7)^8'h5a;end
    for(integer side=0;side<2;side++) begin
      cache_rw[side]=0;bus_rw[side]=0;cache_mode[side]=1;base[side]=0;
      occupied[side]=0;need_data[side]=0;paired[side]=0;got_response[side]=0;up_stalled[side]=0;
      accepted[side]=0;completed[side]=0;acks[side]=0;saved[side]='0;
    end
    event_fd=$fopen("events.csv","w");case_fd=$fopen("cases.csv","w");
    assert(event_fd!=0&&case_fd!=0) else $fatal;
    $fdisplay(event_fd,"time_ps,cycle,case,resetn,a_accept,b_accept,a_complete,b_complete,a_capture,b_capture,pair_valid,pair_ready,match_valid,match_ready,authorized,down_accept,down_complete,address_phase,data_phase,m_ready,m_addr,m_wdata,m_strb,m_rdata,m_resp,m_size,m_burst,m_trans,a_ack,b_ack,a_beat,b_beat,a_accepted,b_accepted,a_completed,b_completed,a_ready,b_ready,fault,a_addr,b_addr,a_wdata,b_wdata,a_strb,b_strb,owner,a_req,b_req");
    $fdisplay(case_fd,"case,start_cycle,end_cycle,controller_cycles,beats");
    $dumpfile("controller-gate.fst");$dumpvars;
    repeat(3) tick();HRESETn=1;tick();
    line_request(0,256,0,0);
    if(!RO) line_request(1,512,0,0);
    line_request(0,512,3,1);
    if(!RO) line_request(1,768,-4,1);
    line_request(0,768,-2,1);
    if(!RO) line_request(1,1024,2,1);
    chain(0,0,1280);
    if(!RO) begin chain(1,0,1664);chain(0,1,2048);end
    single_request(0,256);
    if(!RO) for(integer lane=0;lane<8;lane++) single_request(1,3072+lane);
    single_request(0,3072);
    repeat(4) tick();
    assert(accepted[0]==completed[0]&&accepted[1]==completed[1]&&downs==dones&&downs==completed[0]&&pairs==auths&&auths==downs) else $fatal;
    begin : final_memory_check
      integer actual_fd,expected_fd;
      actual_fd=$fopen("memory-actual.hex","w");expected_fd=$fopen("memory-expected.hex","w");
      assert(actual_fd!=0&&expected_fd!=0) else $fatal;
      for(integer i=0;i<4096;i++) begin
        assert(memory[i]==shadow[i]) else $fatal(1,"final slave memory byte %0d",i);
        $fdisplay(actual_fd,"%h",memory[i]);$fdisplay(expected_fd,"%h",shadow[i]);
      end
      $fclose(actual_fd);$fclose(expected_fd);
    end
    $display("CONTROLLER_GATE_PASS RO=%0d cases=%0d pairs=%0d authorized=%0d accepted=%0d completed=%0d A=%0d B=%0d ackA=%0d ackB=%0d read=%0d write=%0d",RO,cases,pairs,auths,downs,dones,completed[0],completed[1],acks[0],acks[1],reads,writes);
    $fclose(event_fd);$fclose(case_fd);$finish;
  end
  initial begin #200000; $fatal(1,"absolute watchdog");end
endmodule
