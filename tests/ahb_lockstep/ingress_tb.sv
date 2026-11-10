// Independent AHB phase ledger checks all public signals before/after edges.
module ingress_tb;
  logic HCLK = 0, HRESETn = 0;
  logic [55:0] HADDR = 0;
  logic [63:0] HWDATA = 0, HRDATA;
  logic [7:0] HWSTRB = 0;
  logic HWRITE = 0, HMASTLOCK = 0, HREADY, HRESP;
  logic [2:0] HSIZE = 3, HBURST = 0;
  logic [3:0] HPROT = 3;
  logic [1:0] HTRANS, manual_trans = 0;
  bit ready_dependent_source = 0;
  assign HTRANS = ready_dependent_source ? (HREADY ? 2'b10 : 2'b00) : manual_trans;
  logic pending_valid, req_valid, req_ready = 0;
  logic [31:0] req_seq;
  logic [55:0] req_addr;
  logic req_write, req_lock;
  logic [2:0] req_size, req_burst;
  logic [3:0] req_prot;
  logic [1:0] req_trans;
  logic [63:0] req_wdata, rsp_rdata = 0;
  logic [7:0] req_wstrb;
  logic rsp_valid = 0, rsp_ready, rsp_resp = 0;
  ahb_lockstep_ingress dut(.*);
  always #5 HCLK = ~HCLK;

  typedef struct packed {
    logic [55:0] addr;
    logic wr;
    logic [2:0] size, burst;
    logic [3:0] prot;
    logic [1:0] trans;
    logic lock;
  } metadata_t;
  metadata_t saved;
  logic [63:0] saved_wdata = 0, saved_rdata = 0;
  logic [7:0] saved_strb = 0;
  logic [31:0] seq_expected = 0, seq_next = 0;
  bit occupied = 0, need_data = 0, sent = 0, release_ok = 0;
  int error_phase = 0;
  int cycles = 0, checks = 0, accepts = 0, dispatches = 0;
  int responses = 0, completes = 0, cancelled = 0, wait_cycles = 0;
  int trace_file;

  task automatic check_outputs;
    bit expected_ready, expected_req, expected_rsp;
    expected_ready = HRESETn && (!occupied || release_ok || error_phase == 2);
    expected_req = HRESETn && occupied && !need_data && !sent && !release_ok && error_phase == 0;
    expected_rsp = HRESETn && occupied && sent && !release_ok && error_phase == 0;
    assert (HREADY === expected_ready && req_valid === expected_req && rsp_ready === expected_rsp)
      else $fatal(1, "Handshake differs at %0t ready=%b/%b req=%b/%b rsp=%b/%b",
                  $time, HREADY, expected_ready, req_valid, expected_req, rsp_ready, expected_rsp);
    assert (HRESP === (HRESETn && error_phase != 0) && pending_valid === (HRESETn && occupied))
      else $fatal(1, "Response/pending differs at %0t", $time);
    if (HRESETn) begin
      assert ({req_addr,req_write,req_size,req_burst,req_prot,req_trans,req_lock} === saved)
        else $fatal(1, "Saved address/control changed at %0t", $time);
      assert (req_seq === seq_expected && req_wdata === saved_wdata && req_wstrb === saved_strb)
        else $fatal(1, "Saved seq/data/strobe changed at %0t", $time);
      assert (HRDATA === saved_rdata) else $fatal(1, "Read data differs at %0t", $time);
    end else assert (HRDATA === 64'b0) else $fatal(1, "Reset read data");
    checks++;
  endtask

  always @(posedge HCLK) begin : reference_ledger
    bit accept_addr, finish_data, send_request, take_response;
    check_outputs();
    accept_addr = HRESETn && HREADY && HTRANS[1];
    finish_data = HRESETn && occupied && HREADY;
    send_request = req_valid && req_ready;
    take_response = rsp_valid && rsp_ready;
    $fdisplay(trace_file, "%0t,%0d,%b,%b,%b,%h,%b,%b,%b,%b,%b,%b,%b,%0d,%b,%b,%b,%b,%h,%h,%h,%h",
      $time, cycles, HRESETn, HREADY, HRESP, HADDR, HTRANS, HWRITE,
      pending_valid, req_valid, req_ready, rsp_valid, rsp_ready, req_seq,
      accept_addr, finish_data, send_request, take_response, req_addr, req_wdata, req_wstrb, HRDATA);
    if (!HRESETn) begin
      if (occupied) cancelled++;
      occupied = 0; need_data = 0; sent = 0; release_ok = 0; error_phase = 0;
      saved = '0; saved_wdata = 0; saved_strb = 0; saved_rdata = 0;
      seq_expected = 0; seq_next = 0;
    end else begin
      if (occupied && !HREADY) wait_cycles++;
      if (need_data) begin
        saved_wdata = HWDATA; saved_strb = HWSTRB; need_data = 0;
      end
      if (send_request) begin
        dispatches++;
        assert (occupied && !sent) else $fatal(1, "Repeated internal request");
        sent = 1;
      end
      if (take_response) begin
        responses++; saved_rdata = rsp_rdata;
        if (rsp_resp) error_phase = 1; else release_ok = 1;
      end else if (error_phase == 1) error_phase = 2;
      if (finish_data) begin
        completes++;
        assert (sent) else $fatal(1, "Completion before internal dispatch");
        occupied = 0; sent = 0; release_ok = 0; error_phase = 0;
      end
      if (accept_addr) begin
        accepts++;
        assert (!occupied) else $fatal(1, "Overwrite pending address");
        saved = {HADDR,HWRITE,HSIZE,HBURST,HPROT,HTRANS,HMASTLOCK};
        seq_expected = seq_next; seq_next++;
        occupied = 1; need_data = HWRITE; sent = 0;
        saved_wdata = 0; saved_strb = 0;
      end
    end
    cycles++;
    #1;
    check_outputs();
  end

  task automatic step(input logic [1:0] trans, input logic [55:0] addr,
                      input bit wr, input logic [63:0] wd, input logic [7:0] strb,
                      input bit rr, input bit rv, input logic [63:0] rd, input bit err);
    @(negedge HCLK);
    manual_trans = trans; HADDR = addr; HWRITE = wr; HWDATA = wd; HWSTRB = strb;
    req_ready = rr; rsp_valid = rv; rsp_rdata = rd; rsp_resp = err;
    #1; check_outputs();
    @(posedge HCLK); #2;
  endtask

  initial begin
    saved = '0;
    trace_file = $fopen("ingress-cycles.csv", "w");
    assert (trace_file != 0) else $fatal;
    $fdisplay(trace_file, "time_ps,cycle,resetn,hready,hresp,haddr,htrans,hwrite,pending,req_valid,req_ready,rsp_valid,rsp_ready,seq,addr_accept,data_complete,req_dispatch,rsp_capture,req_addr,req_wdata,req_wstrb,hrdata");
    $dumpfile("ingress.vcd"); $dumpvars;
    step(0,0,0,0,0,0,0,0,0);
    HRESETn = 1;
    $display("CASE initial HREADY-dependent request at %0t", $time);
    ready_dependent_source = 1;
    step(0,56'h100,0,0,0,0,0,0,0);
    ready_dependent_source = 0;
    assert (accepts == 1 && !HREADY && req_valid) else $fatal;
    // Request backpressure must preserve one token; later overlap tests hold NONSEQ.
    repeat (3) step(0,0,0,64'hbad,8'hff,0,0,0,0);
    assert (accepts == 1 && dispatches == 0) else $fatal;
    step(0,0,0,0,0,1,0,0,0); // dispatch once
    repeat (3) step(0,0,0,0,0,1,0,64'hbad,0);
    step(0,0,0,0,0,1,1,64'h1111,0); // response saved, ready high now
    assert (HREADY && HRDATA == 'h1111 && completes == 0) else $fatal;
    step(0,0,0,0,0,0,0,0,0); // read completes

    $display("CASE IDLE/BUSY at %0t", $time);
    step(0,56'hbad,1,64'hbad,8'hff,1,1,64'hbad,1);
    step(1,56'hbad,1,64'hbad,8'hff,1,1,64'hbad,1);
    assert (accepts == 1 && !pending_valid && !rsp_ready) else $fatal;

    $display("CASE write capture despite CURRENT HWRITE=0 at %0t", $time);
    HPROT = 4'hf; HMASTLOCK = 1; HSIZE = 0;
    step(2,56'h200,1,64'hffff0000,8'h00,1,0,0,0);
    HPROT = 2; HMASTLOCK = 0; HSIZE = 3;
    step(0,0,0,64'hdeadbeefcafef00d,8'h81,1,0,0,0);
    assert (req_valid && req_write && req_wdata == 64'hdeadbeefcafef00d && req_wstrb == 8'h81)
      else $fatal;
    repeat (2) step(0,56'hbad,0,64'hbad,8'hff,0,0,0,0);
    step(0,0,0,64'hbad,8'hff,1,0,0,0);
    step(0,0,0,0,0,1,1,64'h2222,0);
    // Complete old write and accept NEXT write on the SAME edge.
    $display("CASE release + next address at %0t", $time);
    step(2,56'h300,1,64'hbad,8'h00,0,0,0,0);
    assert (req_addr == 'h300 && !req_valid && !HREADY && completes == 2) else $fatal;
    step(2,56'h308,0,64'h3333,8'h0f,1,0,0,0); // capture data, hold next read address
    step(2,56'h308,0,64'h3333,8'h0f,1,0,0,0); // dispatch
    step(2,56'h308,0,64'h3333,8'h0f,1,1,0,0);
    step(2,56'h308,0,64'h3333,8'h0f,0,0,0,0); // complete write + accept read
    assert (req_addr == 'h308 && !req_write && req_valid && accepts == 4) else $fatal;
    step(0,0,0,0,0,1,0,0,0);
    step(0,0,0,0,0,1,1,64'h4444,0);
    // SEQ is accepted, and HBURST/HTRANS are preserved, not interpreted here.
    HBURST = 5;
    step(3,56'h310,0,0,0,0,0,0,0);
    assert (req_trans == 3 && req_burst == 5 && req_addr == 'h310) else $fatal;
    HBURST = 0;
    step(0,0,0,0,0,1,0,0,0);
    $display("CASE two-cycle error and next address at %0t", $time);
    step(0,0,0,0,0,0,1,64'h5555,1);
    assert (!HREADY && HRESP && HRDATA == 'h5555) else $fatal;
    step(2,56'h400,0,0,0,0,0,64'hbad,0); // ERROR_1 cannot accept address
    assert (HREADY && HRESP && req_addr == 'h310) else $fatal;
    step(2,56'h400,0,0,0,0,0,64'hbad,0); // ERROR_2 completes + accepts
    assert (!HRESP && !HREADY && req_addr == 'h400 && req_valid) else $fatal;
    step(0,0,0,0,0,1,0,0,0);
    step(0,0,0,0,0,0,1,64'h6666,0);
    step(1,0,0,0,0,0,0,0,0); // BUSY while old data completes
    assert (!pending_valid && accepts == 6 && completes == 6) else $fatal;

    $display("CASE reset during capture at %0t", $time);
    step(2,56'h500,1,0,0,0,0,0,0);
    HRESETn = 0;
    step(2,56'hbad,1,64'hbad,8'hff,1,1,64'hbad,1);
    HRESETn = 1;
    step(0,0,0,0,0,0,1,64'hbad,1); // stray response cannot complete anything
    assert (HREADY && !pending_valid && !HRESP) else $fatal;

    $display("CASE reset with dispatched pending read at %0t", $time);
    step(2,56'h600,0,0,0,0,0,0,0);
    step(0,0,0,0,0,1,0,0,0);
    HRESETn = 0;
    step(0,0,0,0,0,0,0,0,0);
    HRESETn = 1;
    step(0,0,0,0,0,0,1,64'hbad,1);
    step(2,56'h700,0,0,0,0,0,0,0);
    assert (req_seq == 0) else $fatal(1, "Sequence must restart after common reset");
    step(0,0,0,0,0,1,0,0,0);
    step(0,0,0,0,0,0,1,64'h7777,0);
    step(0,0,0,0,0,0,0,0,0);
    assert (accepts == 9 && completes == 7 && cancelled == 2 && dispatches == 8 && responses == 7)
      else $fatal(1, "Final accounting mismatch a=%0d c=%0d x=%0d d=%0d r=%0d",
                  accepts, completes, cancelled, dispatches, responses);
    $display("INGRESS_TEST_PASS cycles=%0d checks=%0d accepted=%0d dispatched=%0d responses=%0d completed=%0d reset_cancelled=%0d wait_cycles=%0d",
      cycles, checks, accepts, dispatches, responses, completes, cancelled, wait_cycles);
    $fclose(trace_file); $finish;
  end
endmodule
