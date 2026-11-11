// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module performance_monitor_tb;
  logic clk=0, reset=1, roi_end=0, retire=0;
  logic [4:0] stalls=0;
  logic hresetn=1, hready=1, hresp=0, hwrite=0;
  logic [1:0] htrans=0;
  logic [63:0] haddr=0;
  logic [2:0] hburst=0, hsize=3;
  logic [3:0] hprot=3;
  logic hmastlock=0;
  logic [63:0] mcycle=0, minstret=0;
  logic cycle_inhibit=0, instret_inhibit=0, cycle_write=0, instret_write=0;
  string loaded_memfile="unit";
  performance_monitor dut(.*);
  // Requests are stable from negedge; outputs change only in the NBA region.
  logic release_reset=0, request_end=0, request_abort=0;
  always @(posedge clk) begin
    if (request_abort) reset <= 1;
    else if (release_reset) reset <= 0;
    if (request_end) roi_end <= 1;
  end
  always #5 clk=~clk;
  always @(posedge clk) begin
    if (reset) begin mcycle<=0; minstret<=0; end
    else begin
      mcycle <= cycle_write ? 64'd100 : mcycle + (cycle_inhibit ? 64'd0 : 64'd1);
      minstret <= instret_write ? 64'd200 : minstret + ((retire && !instret_inhibit) ? 64'd1 : 64'd0);
    end
  end
  // Drive only at negedge; assertions inspect settled observer state.
  task automatic tick;
    @(posedge clk); #1; @(negedge clk);
  endtask
  // The aborted ROI is invalid for performance comparison; partial counts
  // must remain available and frozen, including after reset is released.
  task automatic check_aborted_roi;
    assert(dut.done && dut.aborted && !dut.pending)
      else $fatal(1,"abort status/pending");
    assert(dut.start_time==25 && dut.end_time==255 &&
           dut.cpu_cycles==23 && dut.retired_instructions==20)
      else $fatal(1,"aborted ROI boundary/counts");
    assert(dut.ahb_accepted_beats==14 && dut.ahb_completed_beats==12 &&
           dut.ahb_cancelled_beats==2 &&
           dut.ahb_accepted_beats == dut.ahb_completed_beats + dut.ahb_cancelled_beats)
      else $fatal(1,"abort beat conservation");
    assert(dut.ahb_read_beats==11 && dut.ahb_write_beats==1 && dut.ahb_error_beats==1 &&
           dut.ahb_stall_cycles==4 && dut.ahb_completed_wait_cycles==4 &&
           dut.ahb_latency_sum==16 && dut.ahb_latency_min==1 && dut.ahb_latency_max==3)
      else $fatal(1,"cancelled beat must not complete or contribute latency");
    assert(dut.pipeline_any_stall_cycles==5 && dut.stall_f_cycles==5 &&
           dut.stall_d_cycles==0 && dut.stall_e_cycles==5 &&
           dut.stall_m_cycles==0 && dut.stall_w_cycles==5 &&
           dut.csr_cycle_mismatches==0 && dut.csr_instret_mismatches==0 &&
           dut.csr_cycle_inhibited_edges==1 && dut.csr_instret_inhibited_edges==1 &&
           dut.csr_cycle_write_edges==1 && dut.csr_instret_write_edges==1)
      else $fatal(1,"aborted counters must remain frozen");
  endtask
  initial begin
    $dumpfile("performance_monitor.vcd"); $dumpvars(0,performance_monitor_tb);
    tick();
    // Reset is released by NBA on a rising edge: that edge must be excluded.
    release_reset=1;
    @(posedge clk); #1;
    assert(dut.cpu_cycles==0) else $fatal(1,"reset NBA edge included");
    @(negedge clk);
    retire=1; stalls=5'b10101; htrans=2; hwrite=1; hburst=5;
    tick(); // S: accept write
    assert(dut.cpu_cycles==1 && dut.ahb_completed_beats==0) else $fatal;
    htrans=3; hwrite=0; haddr=8;
    tick(); // complete write, accept read (same edge)
    assert(dut.ahb_write_beats==1 && !dut.pending_write) else $fatal;
    hready=0; htrans=0; hresp=1;
    tick(); // first ERROR response edge, not completed
    assert(dut.ahb_completed_beats==1) else $fatal;
    hresp=0; tick(); // second wait
    hready=1; hresp=1; htrans=1;
    tick(); // complete read/error latency 3; BUSY not accepted
    hresp=0; htrans=0; retire=0; stalls=0;
    tick(); // idle
    htrans=2; hwrite=1;
    tick(); // accept to cancel
    hresetn=0; hready=0;
    tick(); // bus reset cancels pending, not stall
    hresetn=1; hready=1; htrans=2; hwrite=0;
    cycle_inhibit=1; instret_inhibit=1; retire=1;
    tick(); // accept read
    htrans=0; cycle_inhibit=0; instret_inhibit=0;
    cycle_write=1; instret_write=1;
    tick(); // read completes latency 1, CSR writes
    cycle_write=0; instret_write=0;
    // INCR8: 8 beats, simultaneous address and data, two wait edges in middle.
    htrans=2; hburst=5;
    tick();
    for (int i=1;i<8;i++) begin
      htrans=3; haddr=64'(i*8);
      if(i==4) begin hready=0; tick(); tick(); hready=1; end
      tick();
    end
    htrans=0; tick(); // final burst data phase
    htrans=2; tick(); // pending at E
    if ($test$plusargs("ABORT")) begin
      request_abort=1; tick(); // 245ps samples reset=0; reset rises in NBA
      assert(reset && !dut.done && !dut.aborted && dut.pending &&
             dut.cpu_cycles==23 && dut.retired_instructions==20 &&
             dut.ahb_accepted_beats==14 && dut.ahb_completed_beats==12 &&
             dut.ahb_cancelled_beats==1)
        else $fatal(1,"reset NBA must not abort the pre-reset edge");
      // 255ps samples reset=1. Present activity to ensure reset takes priority
      // over stalls, retirement, data completion and address acceptance.
      hready=0; stalls=31;
      tick(); // returns at negedge, after monitor and CSR NBA updates
      check_aborted_roi();
      assert(mcycle==0 && minstret==0) else $fatal(1,"CSR reset model");
      repeat (2) begin tick(); check_aborted_roi(); end
      request_abort=0; // release_reset is already asserted
      hready=1; htrans=3;
      tick(); // reset falls in NBA; monitor remains done
      assert(!reset) else $fatal(1,"reset release");
      repeat (2) begin tick(); check_aborted_roi(); end
      $display("PERFORMANCE_ABORT_TEST_PASS: invalid ROI preserved; pending cancelled; counters frozen");
    end else if ($test$plusargs("PENDING_END")) begin
      // Keep the last beat waiting while TestComplete rises in NBA at 245ps.
      hready=0; htrans=0; request_end=1;
      tick();
      assert(!dut.done && dut.pending && dut.pending_wait==1) else $fatal;
      hready=1; htrans=2; // E could complete/accept, but is excluded entirely.
      tick();
      repeat (3) begin
        assert(dut.done && !dut.aborted && dut.pending &&
               dut.start_time==25 && dut.end_time==255 &&
               dut.cpu_cycles==23 && dut.retired_instructions==20)
          else $fatal(1,"pending-at-end ROI/status");
        assert(dut.ahb_accepted_beats==13 && dut.ahb_completed_beats==11 &&
               dut.ahb_cancelled_beats==1 &&
               dut.ahb_accepted_beats == dut.ahb_completed_beats +
                 dut.ahb_cancelled_beats + 1)
          else $fatal(1,"pending-at-end beat conservation");
        assert(dut.ahb_read_beats==10 && dut.ahb_write_beats==1 &&
               dut.ahb_latency_sum==15 && dut.ahb_latency_min==1 &&
               dut.ahb_latency_max==3 && dut.ahb_completed_wait_cycles==4 &&
               dut.ahb_stall_cycles==5)
          else $fatal(1,"unfinished beat excluded from completed latency");
        tick(); // done must freeze even with HREADY=1 and valid address
      end
      $display("PERFORMANCE_PENDING_END_TEST_PASS");
    end else begin
      // TestComplete rises by NBA: this edge still belongs to ROI.
      htrans=0;
      request_end=1;
      @(posedge clk); #1; @(negedge clk);
      htrans=2; // E must not accept even though valid address is presented
      tick();
      assert(dut.cpu_cycles==23 && dut.retired_instructions==20) else $fatal(1,"ROI counters %0d %0d",dut.cpu_cycles,dut.retired_instructions);
      assert(dut.pipeline_any_stall_cycles==5 && dut.stall_f_cycles==5 && dut.stall_d_cycles==0 && dut.stall_e_cycles==5 && dut.stall_m_cycles==0 && dut.stall_w_cycles==5) else $fatal;
      assert(dut.ahb_accepted_beats==13 && dut.ahb_completed_beats==12 && dut.ahb_cancelled_beats==1 && !dut.pending) else $fatal(1,"beat accounting");
      assert(dut.ahb_read_beats==11 && dut.ahb_write_beats==1 && dut.ahb_error_beats==1) else $fatal;
      assert(dut.ahb_stall_cycles==4 && dut.ahb_latency_sum==16 && dut.ahb_latency_min==1 && dut.ahb_latency_max==3) else $fatal;
      assert(dut.csr_cycle_mismatches==0 && dut.csr_instret_mismatches==0 && dut.csr_cycle_write_edges==1 && dut.csr_cycle_inhibited_edges==1) else $fatal;
    end
    $display("PERFORMANCE_MONITOR_TEST_PASS");
    $finish;
  end
endmodule
