// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Observation only. Both real replicas must retire a successful tohost store.
  wire [63:0] dual_pc[2],dual_pcf[2],dual_store_addr[2],dual_store_data[2];
  wire [31:0] dual_instr[2];
  wire dual_retire[2],dual_iack[2];
  assign dual_pc[0]=dut.core.PCM;assign dual_pc[1]=dut.core_b.PCM;
  assign dual_pcf[0]=dut.core.ifu.PCF;assign dual_pcf[1]=dut.core_b.ifu.PCF;
  assign dual_instr[0]=dut.core.InstrM;assign dual_instr[1]=dut.core_b.InstrM;
  assign dual_retire[0]=dut.core.priv.priv.csr.InstrValidNotFlushedM;
  assign dual_retire[1]=dut.core_b.priv.priv.csr.InstrValidNotFlushedM;
  assign dual_iack[0]=dut.core.ifu.bus.icache.ICacheBusAck;
  assign dual_iack[1]=dut.core_b.ifu.bus.icache.ICacheBusAck;
  assign dual_store_addr[0]=dut.core.lsu.IEUAdrM;assign dual_store_addr[1]=dut.core_b.lsu.IEUAdrM;
  assign dual_store_data[0]=dut.core.WriteDataM;assign dual_store_data[1]=dut.core_b.WriteDataM;
  logic [63:0] dual_tohost;
  bit dual_done[2],dual_reported=0,dual_seen_reset=0,dual_started=0;
  integer dual_cycle=0,dual_retired[2],dual_fetch[2],dual_iacks[2],dual_seq[2];
  integer dual_fd,dual_ret_fd,dual_bus_fd,dual_uart_fd,dual_report_fd;
  integer dual_authorized=0,dual_accepted=0,dual_completed=0,dual_up_completed[2];
  integer dual_ram_writes=0,dual_uart_writes=0,dual_chars=0,dual_busy=0,dual_wait=0;
  integer dual_pending_seq=-1,dual_last_authorized=-1,dual_last_completed=-1;
  bit dual_data_owned=0;
  integer dual_burst_left=0;
  logic [P.PA_BITS-1:0] dual_expected_addr;
  initial begin
    // The existing function-only label map omits data symbols such as tohost.
    if(!$value$plusargs("DUAL_TOHOST=%h",dual_tohost)||dual_tohost==0)
      $fatal(1,"DUAL_TOHOST must be resolved from the actual ELF");
    dual_fd=$fopen("dual-events.csv","w");dual_ret_fd=$fopen("retirement.csv","w");
    dual_bus_fd=$fopen("bus-ledger.csv","w");dual_uart_fd=$fopen("uart-ledger.csv","w");
    $fdisplay(dual_fd,"time_ps,cycle,reset,a_pc,b_pc,a_instr,b_instr,a_retired,b_retired,a_addr,b_addr,a_trans,b_trans,a_burst,b_burst,a_write,b_write,a_wdata,b_wdata,a_strb,b_strb,a_ready,b_ready,a_rdata,b_rdata,a_resp,b_resp,pair_valid,pair_ready,match_valid,match_ready,compare_reason,validator_fault,validator_reason,output_state,down_ready,last_authorized,last_completed");
    $fdisplay(dual_ret_fd,"cycle,side,ordinal,pc,instruction,tohost_store");
    $fdisplay(dual_bus_fd,"cycle,a_accept,b_accept,a_complete,b_complete,pair,match,authorized,down_accept,down_complete,owner,addr,write,size,burst,trans,wdata,strb,rdata,resp");
    $fdisplay(dual_uart_fd,"cycle,owner,address,data,character_write");
  end
  task automatic dual_summary(input bit success,input string reason);
    dual_report_fd=$fopen(success?"dual-result.json":"first-failure.json","w");
    $fdisplay(dual_report_fd,"{\"status\":\"%s\",\"reason\":\"%s\",\"cycle\":%0d,\"a_pc\":\"%h\",\"b_pc\":\"%h\",\"a_instr\":\"%h\",\"b_instr\":\"%h\",",success?"PASS":"FAIL",reason,dual_cycle,dual_pc[0],dual_pc[1],dual_instr[0],dual_instr[1]);
    $fdisplay(dual_report_fd,"\"a_retired\":%0d,\"b_retired\":%0d,\"a_fetch\":%0d,\"b_fetch\":%0d,\"a_icache_acks\":%0d,\"b_icache_acks\":%0d,\"a_done\":%0d,\"b_done\":%0d,",dual_retired[0],dual_retired[1],dual_fetch[0],dual_fetch[1],dual_iacks[0],dual_iacks[1],dual_done[0],dual_done[1]);
    $fdisplay(dual_report_fd,"\"authorized\":%0d,\"accepted\":%0d,\"completed\":%0d,\"a_completed\":%0d,\"b_completed\":%0d,\"ram_writes\":%0d,\"uart_writes\":%0d,\"uart_characters\":%0d,\"busy\":%0d,\"data_wait\":%0d,\"last_authorized\":%0d,\"last_completed\":%0d,\"compare_reason\":\"%h\",\"gate_reason\":\"%h\",\"full_F2_acceptance_complete\":false}",dual_authorized,dual_accepted,dual_completed,dual_up_completed[0],dual_up_completed[1],dual_ram_writes,dual_uart_writes,dual_chars,dual_busy,dual_wait,dual_last_authorized,dual_last_completed,dual_compare_reason,dual_gate_reason);
    $fclose(dual_report_fd);$fflush(dual_fd);$fflush(dual_ret_fd);$fflush(dual_bus_fd);$fflush(dual_uart_fd);
  endtask
  task automatic dual_require(input bit condition,input string reason);
    if(!condition) begin dual_summary(0,reason);$fatal(1,"DUAL_FAIL %s",reason);end
  endtask
  always @(posedge clk) begin
    $fdisplay(dual_fd,"%0t,%0d,%b,%h,%h,%h,%h,%0d,%0d,%h,%h,%b,%b,%0d,%0d,%b,%b,%h,%h,%h,%h,%b,%b,%h,%h,%b,%b,%b,%b,%b,%b,%h,%b,%h,%0d,%b,%0d,%0d",$time,dual_cycle,reset,dual_pc[0],dual_pc[1],dual_instr[0],dual_instr[1],dual_retired[0],dual_retired[1],dut.A_HADDR,dut.B_HADDR,dut.A_HTRANS,dut.B_HTRANS,dut.A_HBURST,dut.B_HBURST,dut.A_HWRITE,dut.B_HWRITE,dut.A_HWDATA,dut.B_HWDATA,dut.A_HWSTRB,dut.B_HWSTRB,dut.A_HREADY,dut.B_HREADY,dut.A_HRDATA,dut.B_HRDATA,dut.A_HRESP,dut.B_HRESP,dut.pair_valid,dut.pair_ready,dut.match_valid,dut.match_ready,dual_compare_reason,dut.lockstep_guard.output_backend.burst_mode.validator.fault,dut.lockstep_guard.output_backend.burst_mode.validator.fault_reason,dut.lockstep_guard.output_backend.state,HREADY,dual_last_authorized,dual_last_completed);
    $fflush(dual_fd);
    if(reset) begin
      dual_seen_reset=1;dual_cycle=0;
      for(integer side=0;side<2;side++) begin dual_done[side]=0;dual_retired[side]=0;dual_fetch[side]=0;dual_iacks[side]=0;dual_seq[side]=0;dual_up_completed[side]=0;end
    end else if(dual_seen_reset&&!dual_reported) begin
      if(!dual_started) begin
        dual_started=1;dual_require(dual_pcf[0]==P.RESET_VECTOR&&dual_pcf[1]==P.RESET_VECTOR,"reset_vector");
      end
      dual_require(dual_cycle<250000,"bounded_watchdog");
      dual_require(!dual_fault,"guard_fault");
      dual_require(!dut.A_HRESP&&!dut.B_HRESP,"unexpected_core_error");
      for(integer side=0;side<2;side++) begin
        if(dual_retire[side]) begin
          bit host;
          host=dual_instr[side][6:0]==7'h23&&dual_store_addr[side]==dual_tohost&&dual_store_addr[side]!=0;
          dual_retired[side]++;
          $fdisplay(dual_ret_fd,"%0d,%0d,%0d,%h,%h,%b",dual_cycle,side,dual_retired[side],dual_pc[side],dual_instr[side],host);
          if(host) begin dual_require(dual_store_data[side]==1,"tohost_exit_status");dual_done[side]=1;end
        end
        if(dual_iack[side]) dual_iacks[side]++;
      end
      if(dut.A_HREADY&&dut.A_HTRANS[1]) begin dual_seq[0]++;if(!dut.A_HPROT[0]&&!dut.A_HWRITE) dual_fetch[0]++;end
      if(dut.B_HREADY&&dut.B_HTRANS[1]) begin dual_seq[1]++;if(!dut.B_HPROT[0]&&!dut.B_HWRITE) dual_fetch[1]++;end
      $fdisplay(dual_bus_fd,"%0d,%b,%b,%b,%b,%b,%b,%b,%b,%b,%0d,%h,%b,%0d,%0d,%b,%h,%h,%h,%b",dual_cycle,dut.A_HREADY&&dut.A_HTRANS[1],dut.B_HREADY&&dut.B_HTRANS[1],dut.A_complete,dut.B_complete,dut.pair_valid&&dut.pair_ready,dut.match_valid&&dut.match_ready,dual_auth,dual_accept,dual_complete,dual_owner,HADDR,HWRITE,HSIZE,HBURST,HTRANS,HWDATA,HWSTRB,dut.HRDATA,dut.HRESP);
      if(dual_auth) begin
        dual_require(dut.match_valid&&dut.match_ready,"authorization_without_match");dual_authorized++;dual_last_authorized=dual_authorized-1;
      end
      if(dual_accept) begin
        dual_require(!dual_data_owned&&dual_authorized==dual_accepted+1&&dual_owner==32'(dual_accepted),"address_owner");
        dual_accepted++;dual_data_owned=1;dual_pending_seq=int'(dual_owner);
        if(HBURST==5) begin
          if(HTRANS==2) begin dual_require(dual_burst_left==0,"early_nonseq");dual_burst_left=8;dual_expected_addr=HADDR;end
          dual_require(dual_burst_left>0&&HADDR==dual_expected_addr&&HTRANS==(dual_burst_left==8?2'b10:2'b11),"burst_sequence");
          dual_burst_left--;dual_expected_addr+=P.PA_BITS'(8);
        end else dual_require(HBURST==0&&HTRANS==2&&dual_burst_left==0,"single_shape");
      end
      if(dual_complete) begin
        dual_require(dual_data_owned&&dual_owner==32'(dual_pending_seq)&&!dut.HRESP,"data_owner");dual_completed++;dual_last_completed=dual_pending_seq;dual_data_owned=0;
      end
      if(dut.A_complete) dual_up_completed[0]++;
      if(dut.B_complete) dual_up_completed[1]++;
      dual_require(dut.A_complete==dut.B_complete&&dut.A_rsp_capture==dut.B_rsp_capture,"response_barrier");
      if(dut.uncoregen.uncore.ram.ram.memwriteD) begin dual_require(dual_complete&&HWRITE,"unowned_ram_write");dual_ram_writes++;end
      if(!dut.uncoregen.uncore.uartgen.uart.MEMWb) begin
        dual_require(dual_complete&&HWRITE,"unowned_uart_write");dual_uart_writes++;
        if(dut.uncoregen.uncore.uartgen.uart.uartPC.A==0&&!dut.uncoregen.uncore.uartgen.uart.uartPC.DLAB) dual_chars++;
        $fdisplay(dual_uart_fd,"%0d,%0d,%h,%h,%b",dual_cycle,dual_owner,HADDR,dut.uncoregen.uncore.uartgen.uart.Din,dut.uncoregen.uncore.uartgen.uart.uartPC.A==0&&!dut.uncoregen.uncore.uartgen.uart.uartPC.DLAB);
      end
      if(HTRANS==1) dual_busy++;
      if(dut.data_phase&&!HREADY) dual_wait++;
      if(dual_done[0]&&dual_done[1]&&!dut.A_pending_valid&&!dut.B_pending_valid&&!dual_data_owned&&dual_authorized==dual_completed) begin
        dual_require(dual_fetch[0]>0&&dual_fetch[1]>0&&dual_iacks[0]>0&&dual_iacks[1]>0&&dual_retired[0]>0&&dual_retired[1]>0,"missing_core_progress");
        dual_require(dual_seq[0]==dual_seq[1]&&dual_seq[0]==dual_completed&&dual_up_completed[0]==dual_completed&&dual_up_completed[1]==dual_completed,"final_conservation");
        dual_require(dual_burst_left==0,"incomplete_burst");dual_summary(1,"both_to_host_and_drained");dual_reported=1;
      end
      dual_cycle++;
    end
  end
