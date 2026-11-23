// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Independent AHB acceptance/data ledger + byte RAM side-effect model.
module ebu_gate_tb;
  import cvw::*;
  `include "config.vh"
  `include "parameter-defs.vh"
  localparam integer AW=P.PA_BITS,DW=P.AHBW,SW=DW/8;

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

  // source index: 0=IFU, 1=LSU; two independent replica EBUs.
  logic [1:0] crw[2][2],brw[2][2],ct[2][2];
  logic cmode[2][2],cack[2][2],cstall[2][2],ccommit[2][2],cready[2][2],cwrite[2][2];
  logic [AW-1:0] cbase[2][2],caddr[2][2];
  logic [2:0] cbeat[2][2],csize[2][2],cburst[2][2],lsu_size=3;
  logic [511:0] cfetch[2][2];logic [63:0] cwd[2][2];logic [7:0] cstrb[2][2];
  logic pipe_stall[2][2];
  logic cache_mode[2],ack[2];logic [AW-1:0] base[2];logic [2:0] beat[2];
  logic [2:0] extbeat[2][2];bit saved_origin[2];
  integer local_accepts[2][2],origin_completes[2][2],origin_acks[2][2];
  integer arb_fd,case_start_accept[2],case_origin_beats[2],case_first_origin;
  bit case_has_both=0;logic seen_save[2];
  function automatic logic [63:0] pattern(input logic [AW-1:0] a,input logic [2:0] b);
    return 64'h1032547698badcfe ^ (64'(a)<<16) ^ (64'(b)*64'h01030507090b0d0f);
  endfunction
  for(genvar g=0;g<2;g++) begin: replicas
    assign cache_mode[g]=cmode[g][prot[g][0]];
    assign base[g]=cbase[g][prot[g][0]];
    assign beat[g]=extbeat[g][prot[g][0]];
    assign ack[g]=cack[g][0]||cack[g][1];
    for(genvar k=0;k<2;k++) begin: sources
      ahbcacheinterface #(.P(P),.BEATSPERLINE(8),.AHBWLOGBWPL(3),.LINELEN(512),
        .LLENPOVERAHBW(P.LLEN/P.AHBW),.READ_ONLY_CACHE(k==0)) controller(
        .HCLK,.HRESETn,.HREADY(cready[g][k]),.HTRANS(ct[g][k]),.HWRITE(cwrite[g][k]),
        .HSIZE(csize[g][k]),.HBURST(cburst[g][k]),.HRDATA(rd[g]),.HADDR(caddr[g][k]),
        .HWDATA(cwd[g][k]),.HWSTRB(cstrb[g][k]),.CacheBusAdr(cbase[g][k]),
        .CacheReadDataWordM(pattern(cbase[g][k],cbeat[g][k])),
        .CacheableOrFlushCacheM(k==1 && cmode[g][k]),.Cacheable(cmode[g][k]),
        .CacheBusRW(crw[g][k]),.CacheBusAck(cack[g][k]),.FetchBuffer(cfetch[g][k]),
        .BeatCount(cbeat[g][k]),.SelBusBeat(),.PAdr(cbase[g][k]),
        .WriteDataM(pattern(cbase[g][k],3'd0)),.BusRW(brw[g][k]),.BusAtomic(1'b0),
        .Size(k==0 ? 3'd2 : lsu_size),.BusCMOZero(1'b0),.Stall(pipe_stall[g][k]),
        .Flush(1'b0),.BusStall(cstall[g][k]),.BusCommitted(ccommit[g][k]));
    end
    ebu #(.P(P)) original_ebu(
      .clk(HCLK),.reset(!HRESETn),.IFUHTRANS(ct[g][0]),.IFUHSIZE(csize[g][0]),
      .IFUHBURST(cburst[g][0]),.IFUHADDR(caddr[g][0]),.IFUHREADY(cready[g][0]),
      .LSUHTRANS(ct[g][1]),.LSUHWRITE(cwrite[g][1]),.LSUHSIZE(csize[g][1]),
      .LSUHBURST(cburst[g][1]),.LSUHADDR(caddr[g][1]),.LSUHWDATA(cwd[g][1]),
      .LSUHWSTRB(cstrb[g][1]),.LSUHREADY(cready[g][1]),.HCLK(),.HRESETn(),
      .HREADY(ready[g]),.HRESP(resp[g]),.HADDR(addr[g]),.HWDATA(wd[g]),.HWSTRB(strb[g]),
      .HWRITE(wr[g]),.HSIZE(size[g]),.HBURST(burst[g]),.HPROT(prot[g]),
      .HTRANS(trans[g]),.HMASTLOCK(lock[g]));
    always @(posedge HCLK) if(HRESETn) begin
      if(original_ebu.IFUSave) begin
        assert(original_ebu.LSUSelect&&!original_ebu.IFUSelect) else $fatal(1,"LSU priority");
        seen_save[g]=1;
      end
      assert(cready[g][0]==(ready[g]&&!original_ebu.IFUDisable)) else $fatal;
      assert(cready[g][1]==(ready[g]&&!original_ebu.LSUDisable)) else $fatal;
      for(integer k=0;k<2;k++) if(cready[g][k]&&ct[g][k][1]) local_accepts[g][k]++;
      $fdisplay(arb_fd,"%0t,%0d,%0d,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%0d,%0d,%0d,%b,%b,%b,%b,%h,%h,%h,%h,%h,%h,%b,%b",
        $time,($time-5)/10,g,original_ebu.ebufsmarb.CurrState,original_ebu.ebufsmarb.NextState,
        original_ebu.IFUReq,original_ebu.LSUReq,original_ebu.IFUSave,original_ebu.IFURestore,
        original_ebu.IFUDisable,original_ebu.LSUDisable,original_ebu.IFUSelect,original_ebu.LSUSelect,
        ready[g],cready[g][0],cready[g][1],ct[g][0],ct[g][1],trans[g],
        original_ebu.ebufsmarb.BeatCount,cbeat[g][0],cbeat[g][1],cack[g][0],cack[g][1],
        cmode[g][0],cmode[g][1],caddr[g][0],caddr[g][1],addr[g],cwd[g][1],wd[g],strb[g],
        original_ebu.ebufsmarb.FinalBeatD,original_ebu.ebufsmarb.IFUReqDelay);
    end
  end
  logic [7:0] memory[4096],shadow[4096];
  bit occupied[2],need_data[2],paired[2],got_response[2],cache_req[2];
  logic [63:0] expected_write[2],expected_read,read_words[2][2][8];
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
    for(integer z=0;z<2;z++) for(integer k=0;k<2;k++) ack_read_pending[z][k]=0;
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
          else assert(strb[side]==8'(((64'd1<<(1<<saved[side].size))-64'd1)<<saved[side].addr[2:0])) else $fatal(1,"byte mask");
        end
        if(up_stalled[side]) assert(wd[side]==old_wdata[side]&&strb[side]==old_strb[side]) else $fatal(1,"controller write stability");
        up_stalled[side]=!ready[side];old_wdata[side]=wd[side];old_strb[side]=strb[side];
        if(ack[side]) begin
          assert(cack[side][saved_origin[side]] && !(cack[side][0]&&cack[side][1])) else $fatal(1,"Ack owner");
          origin_acks[side][saved_origin[side]]++;
          ack_read_pending[side][saved_origin[side]]=!saved[side].wr;
          assert((side==0?a_complete:b_complete)&&cache_req[side]&&saved_beat[side]==7&&done)
            else $fatal(1,"early CacheBusAck side=%0d",side);
          acks[side]++;
        end
        if(side==0?a_complete:b_complete) begin
          assert(occupied[side]&&got_response[side]&&rd[side]==expected_read&&!resp[side]) else $fatal(1,"wrong response");
          if(cache_req[side]&&!saved[side].wr) read_words[side][saved_origin[side]][saved_beat[side]]=expected_read;
          origin_completes[side][saved_origin[side]]++;completed[side]++;occupied[side]=0;paired[side]=0;got_response[side]=0;
        end
      end
      if(a_complete&&b_complete) begin authorized=0;issued=0;done=0;end
      for(integer side=0;side<2;side++) if(ready[side]&&trans[side][1]) begin
        assert(!occupied[side]) else $fatal(1,"slot overwritten");
        saved[side]='{addr:addr[side],wr:wr[side],size:size[side],burst:burst[side],prot:prot[side],trans:trans[side],lock:lock[side],data:64'd0,strb:8'd0};
        cache_req[side]=cache_mode[side];saved_beat[side]=beat[side];saved_origin[side]=prot[side][0];
        begin
          integer offset,expected_origin;
          offset=accepted[side]-case_start_accept[side];expected_origin=case_first_origin;
          if(case_has_both && offset>=case_origin_beats[case_first_origin]) expected_origin=1-case_first_origin;
          assert(int'(prot[side][0])==expected_origin) else $fatal(1,"arbitration order case=%s offset=%0d origin=%0d expected=%0d",case_name,offset,prot[side][0],expected_origin);
        end
        if(cache_mode[side]) begin
          assert(burst[side]==5&&size[side]==3&&addr[side]==base[side]+AW'(8*int'(beat[side]))&&
            trans[side]==(beat[side]==0?2'b10:2'b11)) else $fatal(1,"original INCR8 sequence");
        end else assert(burst[side]==0&&trans[side]==2) else $fatal;
        expected_write[side]=cache_mode[side]?pattern(base[side],beat[side]):pattern(base[side],3'd0);
        occupied[side]=1;need_data[side]=wr[side];accepted[side]++;
        if(cache_mode[side]) extbeat[side][prot[side][0]]++;
      end
      assert(cycle-progress<500) else $fatal(1,"progress watchdog");
    end
  end
  task automatic tick; @(posedge HCLK);#2;@(negedge HCLK);endtask
  // Check final FetchBuffer after the NBA update at the Ack edge.
  bit ack_read_pending[2][2];
  for(genvar g=0;g<2;g++) begin: fetch_checker
    for(genvar k=0;k<2;k++) begin: per_source
      always @(negedge HCLK) if(ack_read_pending[g][k]) begin
        for(integer j=0;j<8;j++) assert(cfetch[g][k][64*j+:64]==read_words[g][k][j]) else $fatal(1,"fetch order replica=%0d origin=%0d beat=%0d",g,k,j);
      end
    end
  end
  task automatic scenario(input string label,input bit use_i,input bit use_l,input bit write_l,
    input bit single_l,input integer delta,input integer skew,input bit waits,input integer byte_size=3,input integer lane=0,input integer lsu_address=-1);
    integer start,old_down,old_complete[2][2],old_ack[2][2],old_local[2][2],when_start[2][2],t;
    bit started[2][2],finished;
    case_name=label;start=cycle;old_down=downs;varied_wait=waits;lsu_size=3'(byte_size);t=0;
    case_has_both=use_i&&use_l;case_first_origin=use_i && (!use_l || delta>0)?0:1;
    case_origin_beats[0]=use_i?8:0;case_origin_beats[1]=use_l?(single_l?1:8):0;
    for(integer side=0;side<2;side++) begin
      case_start_accept[side]=accepted[side];seen_save[side]=0;
      for(integer k=0;k<2;k++) begin
        started[side][k]=0;old_complete[side][k]=origin_completes[side][k];old_ack[side][k]=origin_acks[side][k];old_local[side][k]=local_accepts[side][k];
        crw[side][k]=0;brw[side][k]=0;cmode[side][k]=(k==0)||!single_l;
        cbase[side][k]=k==1 && lsu_address>=0 ? AW'(lsu_address)+AW'(lane) : AW'(k==0?256:2048)+AW'(cases)*AW'(128)+(k==1?AW'(lane):AW'(0));pipe_stall[side][k]=1;
        when_start[side][k]=(side==0?(skew<0?-skew:0):(skew>0?skew:0)) + (k==0?(delta<0?-delta:0):(delta>0?delta:0));
      end
    end
    finished=0;
    while(!finished) begin
      for(integer side=0;side<2;side++) for(integer k=0;k<2;k++) begin
        if((k==0?use_i:use_l)&&t==when_start[side][k]) begin
          started[side][k]=1;
          if(cmode[side][k]) crw[side][k]=(k==1&&write_l)?1:2;
          else brw[side][k]=write_l?1:2;
        end
        if(started[side][k] && local_accepts[side][k]>old_local[side][k]) crw[side][k]=0;
        if(started[side][k] && origin_completes[side][k]>old_complete[side][k]) brw[side][k]=0;
      end
      tick();t++;
      finished=1;
      for(integer side=0;side<2;side++) for(integer k=0;k<2;k++)
        if(origin_completes[side][k]-old_complete[side][k]!=case_origin_beats[k]) finished=0;
      assert(t<2000) else $fatal(1,"case watchdog %s",case_name);
    end
    for(integer side=0;side<2;side++) for(integer k=0;k<2;k++) begin
      assert(origin_acks[side][k]-old_ack[side][k]==(case_origin_beats[k]==8?1:0)) else $fatal(1,"Ack count");
      crw[side][k]=0;brw[side][k]=0;pipe_stall[side][k]=0;
    end
    if(use_i&&use_l&&delta<=0) assert(seen_save[0]&&seen_save[1]) else $fatal(1,"save path untested");
    assert(downs-old_down==case_origin_beats[0]+case_origin_beats[1]&&downs==dones) else $fatal;
    cases++;$fdisplay(case_fd,"%s,%0d,%0d,%0d,%0d",case_name,start,cycle,cycle-start,downs-old_down);
    repeat(4) tick();
  endtask
  task automatic chain(input integer origin,input bit first_write,input bit second_write);
    integer aa[2],old_ack[2],old_local[2],start,old_down;
    case_name=$sformatf("chain_origin_%0d_%0d_%0d",origin,first_write,second_write);start=cycle;old_down=downs;varied_wait=1;
    case_has_both=0;case_first_origin=origin;case_origin_beats[origin]=16;case_origin_beats[1-origin]=0;
    for(integer side=0;side<2;side++) begin
      aa[side]=accepted[side];old_ack[side]=origin_acks[side][origin];old_local[side]=local_accepts[side][origin];case_start_accept[side]=accepted[side];
      cmode[side][origin]=1;cbase[side][origin]=AW'(256+cases*128);crw[side][origin]=first_write?1:2;
    end
    while(accepted[0]<aa[0]+8||accepted[1]<aa[1]+8) begin
      for(integer side=0;side<2;side++) if(local_accepts[side][origin]>old_local[side]) crw[side][origin]=0;
      tick();
    end
    for(integer side=0;side<2;side++) begin cbase[side][origin]+=AW'(64);crw[side][origin]=second_write?1:2;end
    while(origin_acks[0][origin]<old_ack[0]+2||origin_acks[1][origin]<old_ack[1]+2) begin
      for(integer side=0;side<2;side++) if(local_accepts[side][origin]>old_local[side]+8) crw[side][origin]=0;
      tick();
    end
    assert(downs-old_down==16&&downs==dones) else $fatal;cases++;
    $fdisplay(case_fd,"%s,%0d,%0d,%0d,%0d",case_name,start,cycle,cycle-start,downs-old_down);repeat(4) tick();
  endtask
  initial begin
    assert(P.BURST_EN&&P.AHBW==64&&P.LLEN==64&&P.DCACHE_LINELENINBITS==512&&P.ICACHE_LINELENINBITS==512) else $fatal;
    for(integer i=0;i<4096;i++) begin memory[i]=8'(i*7)^8'h5a;shadow[i]=8'(i*7)^8'h5a;end
    for(integer side=0;side<2;side++) begin
      occupied[side]=0;need_data[side]=0;paired[side]=0;got_response[side]=0;up_stalled[side]=0;seen_save[side]=0;
      accepted[side]=0;completed[side]=0;acks[side]=0;saved[side]='0;case_start_accept[side]=0;
      for(integer k=0;k<2;k++) begin
        crw[side][k]=0;brw[side][k]=0;cmode[side][k]=1;cbase[side][k]=0;pipe_stall[side][k]=0;
        extbeat[side][k]=0;local_accepts[side][k]=0;origin_completes[side][k]=0;origin_acks[side][k]=0;
      end
    end
    event_fd=$fopen("events.csv","w");case_fd=$fopen("cases.csv","w");arb_fd=$fopen("arbitration.csv","w");
    assert(event_fd!=0&&case_fd!=0&&arb_fd!=0) else $fatal;
    $fdisplay(event_fd,"time_ps,cycle,case,resetn,a_accept,b_accept,a_complete,b_complete,a_capture,b_capture,pair_valid,pair_ready,match_valid,match_ready,authorized,down_accept,down_complete,address_phase,data_phase,m_ready,m_addr,m_wdata,m_strb,m_rdata,m_resp,m_size,m_burst,m_trans,a_ack,b_ack,a_beat,b_beat,a_accepted,b_accepted,a_completed,b_completed,a_ready,b_ready,fault,a_addr,b_addr,a_wdata,b_wdata,a_strb,b_strb,owner,a_req,b_req");
    $fdisplay(arb_fd,"time_ps,cycle,replica,state,next_state,ifu_req,lsu_req,save,restore,ifu_disable,lsu_disable,ifu_select,lsu_select,guard_ready,ifu_ready,lsu_ready,ifu_trans,lsu_trans,ebu_trans,arb_beat,ifu_beat,lsu_beat,ifu_ack,lsu_ack,ifu_cache,lsu_cache,ifu_addr,lsu_addr,ebu_addr,lsu_wdata,ebu_wdata,ebu_strb,final_beat_d,ifu_req_delay");
    $fdisplay(case_fd,"case,start_cycle,end_cycle,controller_cycles,beats");$dumpfile("ebu-gate.fst");$dumpvars;
    repeat(3) tick();HRESETn=1;tick();
    scenario("ifu_only_zero",1,0,0,0,0,0,0);
    scenario("lsu_read_zero",0,1,0,0,0,0,0);
    scenario("lsu_write_zero",0,1,1,0,0,0,0);
    scenario("lsu_writeback_readback",0,1,0,0,0,0,1,3,0,2304);
    scenario("both_read",1,1,0,0,0,0,1);
    scenario("both_write",1,1,1,0,0,0,1);
    scenario("both_uncached_read",1,1,0,1,0,0,1);
    scenario("both_uncached_write",1,1,1,1,0,0,1);
    scenario("ifu_then_lsu",1,1,0,0,2,0,1);
    scenario("lsu_then_ifu",1,1,1,0,-2,0,1);
    scenario("A_early_both",1,1,1,0,0,3,1);
    scenario("B_early_both",1,1,0,0,0,-3,1);
    scenario("A_early_ifu_then_lsu",1,1,1,0,2,2,1);
    chain(0,0,0);chain(1,0,0);chain(1,1,0);chain(1,0,1);
    scenario("burst_then_single",0,1,0,1,0,0,1);
    for(integer lane=0;lane<8;lane++) scenario($sformatf("uncached_byte_%0d",lane),0,1,1,1,0,0,1,0,lane,3584);
    scenario("uncached_readback",0,1,0,1,0,0,1,3,0,3584);
    repeat(4) tick();
    assert(accepted[0]==completed[0]&&accepted[1]==completed[1]&&downs==dones&&downs==completed[0]&&pairs==auths&&auths==downs) else $fatal;
    begin
      integer actual_fd,expected_fd;
      actual_fd=$fopen("memory-actual.hex","w");expected_fd=$fopen("memory-expected.hex","w");
      assert(actual_fd!=0&&expected_fd!=0) else $fatal;
      for(integer i=0;i<4096;i++) begin
        assert(memory[i]==shadow[i]) else $fatal(1,"memory byte %0d",i);
        $fdisplay(actual_fd,"%h",memory[i]);$fdisplay(expected_fd,"%h",shadow[i]);
      end
      $fclose(actual_fd);$fclose(expected_fd);
    end
    $display("EBU_GATE_PASS cases=%0d pairs=%0d authorized=%0d accepted=%0d completed=%0d A=%0d B=%0d ackA=%0d ackB=%0d read=%0d write=%0d",cases,pairs,auths,downs,dones,completed[0],completed[1],acks[0],acks[1],reads,writes);
    $fclose(event_fd);$fclose(case_fd);$fclose(arb_fd);$finish;
  end
  initial begin #200000; $fatal(1,"absolute watchdog");end
endmodule
