// Original CV-Wally AHB controllers, without instantiating a processor Core.
module ingress_cvw_tb;
  parameter bit CACHE_MODE = 0;
  logic HCLK = 0, HRESETn = 0;
  always #5 HCLK = ~HCLK;
  logic [55:0] HADDR;
  logic [63:0] HWDATA, HRDATA;
  logic [7:0] HWSTRB;
  logic HWRITE, HMASTLOCK = 0, HREADY, HRESP;
  logic [2:0] HSIZE = 3, HBURST;
  logic [3:0] HPROT = 3;
  logic [1:0] HTRANS;
  logic pending_valid, req_valid, req_ready;
  logic [31:0] req_seq;
  logic [55:0] req_addr;
  logic req_write, req_lock;
  logic [2:0] req_size, req_burst;
  logic [3:0] req_prot;
  logic [1:0] req_trans;
  logic [63:0] req_wdata;
  logic [7:0] req_wstrb;
  logic rsp_valid, rsp_ready;
  logic [63:0] rsp_rdata;
  logic rsp_resp = 0;
  ahb_lockstep_ingress dut(.*);

  logic [1:0] source_rw = 0;
  logic [55:0] source_addr = 56'h80000000;
  logic [63:0] source_wdata = 'habcdef0123456789, fetch_buffer;
  logic [7:0] source_mask = 8'h5a;
  logic bus_stall, bus_committed, cache_ack;
  if (!CACHE_MODE) begin : single_source
    assign HADDR = source_addr;
    assign HBURST = 0;
    assign cache_ack = 0;
    ahbinterface #(.XLEN(64), .LSU(1'b1)) original_source (
      .HCLK, .HRESETn, .HREADY, .HTRANS, .HWRITE, .HRDATA, .HWDATA, .HWSTRB,
      .Stall(1'b0), .Flush(1'b0), .BusRW(source_rw), .BusAtomic(1'b0),
      .ByteMask(source_mask), .WriteData(source_wdata),
      .BusStall(bus_stall), .BusCommitted(bus_committed), .FetchBuffer(fetch_buffer)
    );
  end else begin : burst_source
    logic [2:0] beat, delayed_beat;
    logic capture_en, sel_bus_beat;
    assign HADDR = source_addr + (56'(beat) << 3);
    assign HWDATA = 0;
    assign HWSTRB = 0;
    assign fetch_buffer = 0;
    buscachefsm #(.BeatCountThreshold(7), .AHBWLOGBWPL(3),
                  .READ_ONLY_CACHE(1'b1), .BURST_EN(1'b1)) original_source (
      .HCLK, .HRESETn, .Stall(1'b0), .Flush(1'b0), .BusRW(2'b00),
      .BusAtomic(1'b0), .BusCMOZero(1'b0), .BusStall(bus_stall),
      .BusCommitted(bus_committed), .CaptureEn(capture_en),
      .CacheBusRW(source_rw), .CacheBusAck(cache_ack), .BeatCount(beat),
      .BeatCountDelayed(delayed_beat), .SelBusBeat(sel_bus_beat),
      .HREADY, .HTRANS, .HWRITE, .HBURST
    );
  end

  // A request is consumed ONCE; wait three cycles, then hold response valid
  // until accepted. This stub is not a Memory/Uncore or an Output Gate.
  bit active = 0;
  int delay_left = 0, requests = 0, completions = 0, accepts = 0, ack_count = 0;
  logic [63:0] response_payload = 0;
  logic [31:0] last_seq = 0;
  logic [55:0] last_addr = 0;
  bit ahb_pending = 0;
  assign req_ready = HRESETn && !active;
  assign rsp_valid = HRESETn && active && (delay_left == 0);
  assign rsp_rdata = response_payload;
  always @(posedge HCLK) begin
    if (!HRESETn) begin
      active <= 0; delay_left <= 0; ahb_pending <= 0;
    end else begin
      if (ahb_pending && HREADY) begin
        completions++;
        ahb_pending <= 0;
        $display("[CVW] mode=%b complete=%0d time=%0t data=%h", CACHE_MODE, completions, $time, HRDATA);
      end
      if (HREADY && HTRANS[1]) begin accepts++; ahb_pending <= 1; end
      if (cache_ack) ack_count++;
      if (req_valid && req_ready) begin
        assert (!active && req_seq == 32'(requests)) else $fatal(1, "Duplicate sequence");
        if (CACHE_MODE) begin
          assert (!req_write && req_burst == 5 && req_addr == source_addr + 56'(requests*8)) else $fatal;
          assert (req_trans == (requests == 0 ? 2'b10 : 2'b11)) else $fatal;
        end else begin
          assert (req_addr == source_addr && req_write == (source_rw == 1)) else $fatal;
          if (req_write) assert (req_wdata == source_wdata && req_wstrb == source_mask) else $fatal;
        end
        requests++;
        last_seq <= req_seq; last_addr <= req_addr;
        response_payload <= 64'(req_addr) ^ 64'h55aa55aa55aa55aa;
        active <= 1; delay_left <= 3;
      end else if (active && delay_left != 0) delay_left <= delay_left - 1;
      else if (rsp_valid && rsp_ready) active <= 0;
      if (active) begin
        assert (req_addr == last_addr && req_seq == last_seq) else $fatal(1, "Pending changed");
        assert (!HREADY) else $fatal(1, "Premature upstream completion");
      end
    end
  end

  initial begin
    $dumpfile("ingress-cvw.vcd"); $dumpvars;
    repeat (3) @(negedge HCLK);
    HRESETn = 1;
    @(negedge HCLK);
    assert (HREADY) else $fatal(1, "No initial credit for HREADY-dependent source");
    source_rw = 2;
    if (CACHE_MODE) begin
      // CacheBusRW starts a line request, then the original FSM generates SEQ.
      wait (accepts == 1); @(negedge HCLK); source_rw = 0;
      wait (ack_count == 1); @(negedge HCLK);
      repeat (3) @(negedge HCLK);
      assert (requests == 8 && accepts == 8 && completions == 8 && ack_count == 1 && !pending_valid)
        else $fatal(1, "Cache FSM totals req=%0d addr=%0d done=%0d ack=%0d", requests, accepts, completions, ack_count);
    end else begin
      wait (completions == 1); @(negedge HCLK); source_rw = 0;
      assert (fetch_buffer == (64'(source_addr) ^ 64'h55aa55aa55aa55aa)) else $fatal(1, "FetchBuffer did not get saved response");
      repeat (3) @(negedge HCLK);
      source_addr = 56'h80000100; source_rw = 1;
      wait (completions == 2); @(negedge HCLK); source_rw = 0;
      repeat (3) @(negedge HCLK);
      assert (requests == 2 && accepts == 2 && !pending_valid) else $fatal;
    end
    $display("CVW_INGRESS_TEST_PASS mode=%b accepted=%0d dispatched=%0d completed=%0d cache_ack=%0d",
             CACHE_MODE, accepts, requests, completions, ack_count);
    $finish;
  end
  initial begin
    #10000;
    $fatal(1, "Deadlock timeout mode=%b", CACHE_MODE);
  end
endmodule
