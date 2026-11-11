// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Passive, pre-NBA rising-edge observer. S inclusive, E exclusive.
module performance_monitor # (parameter int XLEN=64)(
  input logic clk, reset, roi_end, retire,
  input logic [4:0] stalls, // bit 0=F, 1=D, 2=E, 3=M, 4=W
  input logic hresetn, hready, hresp, hwrite,
  input logic [1:0] htrans,
  input logic [XLEN-1:0] haddr,
  input logic [2:0] hburst, hsize,
  input logic [3:0] hprot,
  input logic hmastlock,
  input logic [63:0] mcycle, minstret,
  input logic cycle_inhibit, instret_inhibit, cycle_write, instret_write,
  input string loaded_memfile
);
  bit enabled, seen_reset, active, done, pending, aborted;
  bit pending_write;
  logic [XLEN-1:0] pending_addr;
  logic [2:0] pending_burst, pending_size;
  logic [3:0] pending_prot;
  logic pending_lock;
  longint unsigned edge_index, accepted_edge, pending_wait;
  longint unsigned start_time, end_time, latency;
  longint unsigned cycle_start, instret_start, previous_cycle, previous_instret;
  bit check_previous, previous_retire, previous_ci, previous_ii, previous_cw, previous_iw;
  string output_file;
  integer fd;
  longint unsigned cpu_cycles, retired_instructions, pipeline_any_stall_cycles, stall_f_cycles, stall_d_cycles, stall_e_cycles, stall_m_cycles, stall_w_cycles, ahb_accepted_beats, ahb_completed_beats, ahb_read_beats, ahb_write_beats, ahb_error_beats, ahb_stall_cycles, ahb_latency_sum, ahb_latency_min, ahb_latency_max, ahb_completed_wait_cycles, ahb_cancelled_beats, csr_cycle_inhibited_edges, csr_instret_inhibited_edges, csr_cycle_write_edges, csr_instret_write_edges, csr_cycle_mismatches, csr_instret_mismatches;
  initial begin
    enabled = $value$plusargs("PERFORMANCE_JSON=%s", output_file);
  end

  task automatic report_result;
    fd = $fopen(output_file, "w");
    if (fd == 0) $fatal(1, "Cannot open performance output %s", output_file);
    $fdisplay(fd, "{");
    $fdisplay(fd, "  \"roi\": \"reset_release_to_tb_complete_v1\",");
    $fdisplay(fd, "  \"loaded_memfile\": \"%s\",", loaded_memfile);
    $fdisplay(fd, "  \"start_time\": %0d, \"end_time\": %0d,", start_time, end_time);
    $fdisplay(fd, "  \"aborted\": %0d, \"pending_at_end\": %0d,", aborted, pending);
    $fdisplay(fd, "  \"mcycle_delta\": %0d, \"minstret_delta\": %0d,", mcycle-cycle_start, minstret-instret_start);
    $fdisplay(fd, "  \"cpu_cycles\": %0d,", cpu_cycles);
    $fdisplay(fd, "  \"retired_instructions\": %0d,", retired_instructions);
    $fdisplay(fd, "  \"pipeline_any_stall_cycles\": %0d,", pipeline_any_stall_cycles);
    $fdisplay(fd, "  \"stall_f_cycles\": %0d,", stall_f_cycles);
    $fdisplay(fd, "  \"stall_d_cycles\": %0d,", stall_d_cycles);
    $fdisplay(fd, "  \"stall_e_cycles\": %0d,", stall_e_cycles);
    $fdisplay(fd, "  \"stall_m_cycles\": %0d,", stall_m_cycles);
    $fdisplay(fd, "  \"stall_w_cycles\": %0d,", stall_w_cycles);
    $fdisplay(fd, "  \"ahb_accepted_beats\": %0d,", ahb_accepted_beats);
    $fdisplay(fd, "  \"ahb_completed_beats\": %0d,", ahb_completed_beats);
    $fdisplay(fd, "  \"ahb_read_beats\": %0d,", ahb_read_beats);
    $fdisplay(fd, "  \"ahb_write_beats\": %0d,", ahb_write_beats);
    $fdisplay(fd, "  \"ahb_error_beats\": %0d,", ahb_error_beats);
    $fdisplay(fd, "  \"ahb_stall_cycles\": %0d,", ahb_stall_cycles);
    $fdisplay(fd, "  \"ahb_latency_sum\": %0d,", ahb_latency_sum);
    $fdisplay(fd, "  \"ahb_latency_min\": %0d,", ahb_latency_min);
    $fdisplay(fd, "  \"ahb_latency_max\": %0d,", ahb_latency_max);
    $fdisplay(fd, "  \"ahb_completed_wait_cycles\": %0d,", ahb_completed_wait_cycles);
    $fdisplay(fd, "  \"ahb_cancelled_beats\": %0d,", ahb_cancelled_beats);
    $fdisplay(fd, "  \"csr_cycle_inhibited_edges\": %0d,", csr_cycle_inhibited_edges);
    $fdisplay(fd, "  \"csr_instret_inhibited_edges\": %0d,", csr_instret_inhibited_edges);
    $fdisplay(fd, "  \"csr_cycle_write_edges\": %0d,", csr_cycle_write_edges);
    $fdisplay(fd, "  \"csr_instret_write_edges\": %0d,", csr_instret_write_edges);
    $fdisplay(fd, "  \"csr_cycle_mismatches\": %0d,", csr_cycle_mismatches);
    $fdisplay(fd, "  \"csr_instret_mismatches\": %0d,", csr_instret_mismatches);
    $fdisplay(fd, "  \"cpi\": %0.9f,", (retired_instructions != 0) ? real'(cpu_cycles)/real'(retired_instructions) : 0.0);
    $fdisplay(fd, "  \"ahb_latency_mean\": %0.9f", (ahb_completed_beats != 0) ? real'(ahb_latency_sum)/real'(ahb_completed_beats) : 0.0);
    $fdisplay(fd, "}");
    $fclose(fd);
    $display("PERFORMANCE_ROI_DONE S=%0d E=%0d cycles=%0d retired=%0d", start_time, end_time, cpu_cycles, retired_instructions);
  endtask

  // Blocking assignments are intentional: local observer state only. No DUT writes.
  always @(posedge clk) if (enabled && !done) begin
    edge_index = edge_index + 1;
    if (check_previous && !reset) begin
      if (!previous_cw && mcycle != previous_cycle + (previous_ci ? 64'd0 : 64'd1))
        csr_cycle_mismatches++;
      if (!previous_iw && minstret != previous_instret + ((previous_retire && !previous_ii) ? 64'd1 : 64'd0))
        csr_instret_mismatches++;
    end
    if (reset) begin
      seen_reset = 1;
      if (active) begin
        // A CPU reset invalidates this ROI. Preserve the partial evidence.
        aborted = 1;
        if (pending) begin ahb_cancelled_beats++; pending=0; end
        end_time = $time;
        done=1;
        report_result();
      end
    end else if (seen_reset) begin
      if (!active) begin
        active=1;
        start_time=$time;
        cycle_start=mcycle;
        instret_start=minstret;
      end
      if (roi_end) begin
        end_time=$time;
        done=1;
        report_result();
      end else begin
        cpu_cycles++;
        if (retire) retired_instructions++;
        if (|stalls) pipeline_any_stall_cycles++;
        if (stalls[0]) stall_f_cycles++;
        if (stalls[1]) stall_d_cycles++;
        if (stalls[2]) stall_e_cycles++;
        if (stalls[3]) stall_m_cycles++;
        if (stalls[4]) stall_w_cycles++;
        if (cycle_inhibit) csr_cycle_inhibited_edges++;
        if (instret_inhibit) csr_instret_inhibited_edges++;
        if (cycle_write) csr_cycle_write_edges++;
        if (instret_write) csr_instret_write_edges++;
        if (!hresetn) begin
          if (pending) ahb_cancelled_beats++;
          pending=0;
        end else begin
          if (pending) begin
            if (!hready) begin ahb_stall_cycles++; pending_wait++; end
            else begin
              latency=edge_index-accepted_edge;
              assert(latency == 1+pending_wait) else $fatal(1, "AHB latency invariant");
              ahb_completed_beats++;
              if (pending_write) ahb_write_beats++; else ahb_read_beats++;
              if (hresp) ahb_error_beats++;
              ahb_latency_sum+=latency;
              ahb_completed_wait_cycles+=pending_wait;
              if (ahb_completed_beats==1 || latency<ahb_latency_min) ahb_latency_min=latency;
              if (latency>ahb_latency_max) ahb_latency_max=latency;
              pending=0;
            end
          end
          // Complete the OLD data phase before accepting the NEW address.
          if (hready && htrans[1]) begin
            pending=1;
            pending_write=hwrite;
            pending_addr=haddr;
            pending_burst=hburst;
            pending_size=hsize;
            pending_prot=hprot;
            pending_lock=hmastlock;
            accepted_edge=edge_index;
            pending_wait=0;
            ahb_accepted_beats++;
          end
        end
        previous_cycle=mcycle; previous_instret=minstret;
        previous_retire=retire; previous_ci=cycle_inhibit; previous_ii=instret_inhibit;
        previous_cw=cycle_write; previous_iw=instret_write;
        check_previous=1;
      end
    end
  end
endmodule
