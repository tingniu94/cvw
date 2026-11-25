// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Passive pre-NBA trace. Only the testbench completion policy is selected.
`ifdef CVW_DUAL_CORE
  localparam integer G3_CORES=2,G3_BUSES=3;
`else
  localparam integer G3_CORES=1,G3_BUSES=1;
`endif
  wire [63:0] g3_pc[G3_CORES],g3_store_addr[G3_CORES],g3_store_data[G3_CORES];
  wire [63:0] g3_mc[G3_CORES],g3_mi[G3_CORES];
  wire [31:0] g3_ins[G3_CORES];
  wire [4:0] g3_stall[G3_CORES];
  wire [3:0] g3_memory_stall[G3_CORES],g3_csr_flags[G3_CORES];
  wire g3_retire[G3_CORES];
`define G3_CORE(I,C) \
  assign g3_pc[I]=dut.C.PCM; \
  assign g3_ins[I]=dut.C.InstrM; \
  assign g3_store_addr[I]=dut.C.lsu.IEUAdrM; \
  assign g3_store_data[I]=dut.C.WriteDataM; \
  assign g3_retire[I]=dut.C.priv.priv.csr.InstrValidNotFlushedM; \
  assign g3_stall[I]={dut.C.StallW,dut.C.StallM,dut.C.StallE,dut.C.StallD,dut.C.StallF}; \
  assign g3_memory_stall[I]={dut.C.LSUStallM,dut.C.IFUStallF,dut.C.DCacheStallM,dut.C.ICacheStallF}; \
  assign g3_mc[I]=dut.C.priv.priv.csr.counters.HPMCOUNTER_REGW[0]; \
  assign g3_mi[I]=dut.C.priv.priv.csr.counters.HPMCOUNTER_REGW[2]; \
  assign g3_csr_flags[I]={dut.C.priv.priv.csr.counters.WriteHPMCOUNTERM[2],dut.C.priv.priv.csr.counters.WriteHPMCOUNTERM[0],dut.C.priv.priv.csr.MCOUNTINHIBIT_REGW[2],dut.C.priv.priv.csr.MCOUNTINHIBIT_REGW[0]};
  `G3_CORE(0,core)
`ifdef CVW_DUAL_CORE
  `G3_CORE(1,core_b)
`endif
`undef G3_CORE
  wire [P.PA_BITS-1:0] g3_addr[G3_BUSES];
  wire [P.AHBW-1:0] g3_wdata[G3_BUSES],g3_rdata[G3_BUSES];
  wire [P.XLEN/8-1:0] g3_strb[G3_BUSES];
  wire [1:0] g3_trans[G3_BUSES];
  wire [2:0] g3_burst[G3_BUSES],g3_size[G3_BUSES];
  wire g3_ready[G3_BUSES],g3_resp[G3_BUSES],g3_write[G3_BUSES];
`define G3_BUS(I,A,W,S,T,B,Z,R,E,D,X) \
  assign g3_addr[I]=A;assign g3_wdata[I]=W;assign g3_strb[I]=S; \
  assign g3_trans[I]=T;assign g3_burst[I]=B;assign g3_size[I]=Z; \
  assign g3_ready[I]=R;assign g3_resp[I]=E;assign g3_rdata[I]=D;assign g3_write[I]=X;
`ifdef CVW_DUAL_CORE
  `G3_BUS(0,dut.A_HADDR,dut.A_HWDATA,dut.A_HWSTRB,dut.A_HTRANS,dut.A_HBURST,dut.A_HSIZE,dut.A_HREADY,dut.A_HRESP,dut.A_HRDATA,dut.A_HWRITE)
  `G3_BUS(1,dut.B_HADDR,dut.B_HWDATA,dut.B_HWSTRB,dut.B_HTRANS,dut.B_HBURST,dut.B_HSIZE,dut.B_HREADY,dut.B_HRESP,dut.B_HRDATA,dut.B_HWRITE)
  `G3_BUS(2,HADDR,HWDATA,HWSTRB,HTRANS,HBURST,HSIZE,HREADY,dut.HRESP,dut.HRDATA,HWRITE)
`else
  `G3_BUS(0,HADDR,HWDATA,HWSTRB,HTRANS,HBURST,HSIZE,HREADY,dut.HRESP,dut.HRDATA,HWRITE)
`endif
`undef G3_BUS
  bit g3_seen_reset=0,g3_started=0,g3_finished=0,g3_trace_done=0;
  bit g3_host_done[G3_CORES],g3_pending[G3_BUSES];
  integer g3_cycle=0,g3_cpu_fd,g3_bus_fd,g3_guard_fd;
  logic [63:0] g3_tohost;
  initial begin
    if(!$value$plusargs("DUAL_TOHOST=%h",g3_tohost)||g3_tohost==0) $fatal(1,"Missing ELF tohost symbol");
    g3_cpu_fd=$fopen("cpu-samples.csv","w");g3_bus_fd=$fopen("ahb-samples.csv","w");
    g3_guard_fd=$fopen("guard-samples.csv","w");
    $fdisplay(g3_cpu_fd,"time_ps,cycle,core,common_end,legacy_end,pc,instruction,retire,tohost,stalls,memory_stalls,mcycle,minstret,csr_flags");
    $fdisplay(g3_bus_fd,"cycle,bus,hresetn,ready,resp,trans,burst,size,addr,write,wdata,strb,rdata");
    $fdisplay(g3_guard_fd,"cycle,state,a_offer,b_offer,pair_valid,pair_ready,match_valid,match_ready,auth,accept,complete,response_pending,a_capture,b_capture,a_complete,b_complete,a_pending,b_pending,owner,busy_gap,peer_counter,pair_bp_counter");
  end
  always @(posedge clk) begin : g3_observe
    bit host,all_done,all_drained;
    if(reset) begin
      assert(!g3_started) else $fatal(1,"Reset aborts performance ROI");
      g3_seen_reset=1;
    end else if(g3_seen_reset&&!g3_trace_done) begin
      g3_started=1;
      assert(g3_cycle<250000) else $fatal(1,"Performance watchdog");
      for(integer i=0;i<G3_CORES;i++) begin
        host=g3_retire[i]&&g3_ins[i][6:0]==7'h23&&g3_store_addr[i]==g3_tohost;
        $fdisplay(g3_cpu_fd,"%0t,%0d,%0d,%b,%b,%h,%h,%b,%b,%b,%b,%h,%h,%b",$time,g3_cycle,i,g3_finished,CurrState==STATE_RUN_TEST&&TestComplete,g3_pc[i],g3_ins[i],g3_retire[i],host,g3_stall[i],g3_memory_stall[i],g3_mc[i],g3_mi[i],g3_csr_flags[i]);
        if(host) begin
          assert(g3_store_data[i]==1) else $fatal(1,"Unsuccessful tohost store");
          g3_host_done[i]=1;
        end
      end
      all_drained=1;
      for(integer b=0;b<G3_BUSES;b++) begin
        $fdisplay(g3_bus_fd,"%0d,%0d,%b,%b,%b,%b,%0d,%0d,%h,%b,%h,%h,%h",g3_cycle,b,HRESETn,g3_ready[b],g3_resp[b],g3_trans[b],g3_burst[b],g3_size[b],g3_addr[b],g3_write[b],g3_wdata[b],g3_strb[b],g3_rdata[b]);
        if(g3_pending[b]&&g3_ready[b]) g3_pending[b]=0;
        if(HRESETn&&g3_ready[b]&&g3_trans[b][1]) g3_pending[b]=1;
        if(g3_pending[b]) all_drained=0;
      end
`ifdef CVW_DUAL_CORE
      $fdisplay(g3_guard_fd,"%0d,%0d,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%0d,%b,%0d,%0d",g3_cycle,dut.lockstep_guard.output_backend.state,dut.lockstep_guard.A_req_valid,dut.lockstep_guard.B_req_valid,dut.pair_valid,dut.pair_ready,dut.match_valid,dut.match_ready,dual_auth,dual_accept,dual_complete,dut.response_pending,dut.A_rsp_capture,dut.B_rsp_capture,dut.A_complete,dut.B_complete,dut.A_pending_valid,dut.B_pending_valid,dual_owner,dut.lockstep_guard.output_backend.busy_gap,dual_peer,dual_backpressure);
      assert(!dual_fault) else $fatal(1,"Unexpected Guard fault");
`endif
      all_done=1;
      for(integer i=0;i<G3_CORES;i++) if(!g3_host_done[i]) all_done=0;
      if(all_done&&all_drained) g3_finished<=1;
      if(CurrState==STATE_RUN_TEST&&TestComplete) begin
        assert(g3_finished) else $fatal(1,"Premature test completion");
        g3_trace_done=1;
        $fflush(g3_cpu_fd);$fflush(g3_bus_fd);$fflush(g3_guard_fd);
      end
      g3_cycle++;
    end
  end
