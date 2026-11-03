// AHB source/slave stimulus and an independent completed-beat scoreboard.
module shared_guard_tb;
  logic HCLK = 0, HRESETn = 0;
  logic [55:0] A_HADDR = 0, HADDR;
  logic [63:0] A_HWDATA = 0, HWDATA, HRDATA = 0, A_HRDATA;
  logic [7:0] A_HWSTRB = 0, HWSTRB;
  logic A_HWRITE = 0, HWRITE, A_HMASTLOCK = 0, HMASTLOCK;
  logic [2:0] A_HSIZE = 0, HSIZE, A_HBURST = 0, HBURST;
  logic [3:0] A_HPROT = 0, HPROT;
  logic [1:0] A_HTRANS = 0, HTRANS;
  logic HREADY = 1, A_HREADY, HRESP = 0, A_HRESP;
  ahb_shared_guard dut(.*);
  always #5 HCLK = ~HCLK;

  bit pending = 0;
  logic [55:0] pending_addr;
  bit pending_write;
  int accepted = 0, completed = 0, reads = 0, writes = 0;
  int stalled = 0, errors = 0, burst_accepted = 0, burst_completed = 0;
  int last_waits = 0, pending_waits = 0;
  logic [55:0] last_addr;
  logic [63:0] last_data;
  logic [7:0] last_strb;
  bit pending_burst;

  task automatic check_transparency;
    assert ({HADDR,HWRITE,HSIZE,HBURST,HPROT,HTRANS,HMASTLOCK,HWDATA,HWSTRB}
            === {A_HADDR,A_HWRITE,A_HSIZE,A_HBURST,A_HPROT,A_HTRANS,
                 A_HMASTLOCK,A_HWDATA,A_HWSTRB})
      else $fatal(1, "Request/data changed at %0t", $time);
    assert ({A_HRDATA,A_HREADY,A_HRESP} === {HRDATA,HREADY,HRESP})
      else $fatal(1, "Response changed at %0t", $time);
  endtask

  // Save ADDRESS metadata, then use it with the following DATA phase.
  // An IDLE address while pending must not cancel the previous transfer.
  always @(posedge HCLK) begin
    check_transparency();
    if (!HRESETn) begin
      pending = 0;
      pending_waits = 0;
    end else if (HREADY) begin
      if (pending) begin
        completed++;
        if (pending_write) writes++; else reads++;
        if (pending_burst) burst_completed++;
        if (HRESP) errors++;
        last_addr = pending_addr;
        last_data = pending_write ? HWDATA : A_HRDATA;
        last_strb = HWSTRB;
        last_waits = pending_waits;
        $display("[SHARED_TB] complete=%0d addr=%h write=%b data=%h waits=%0d resp=%b",
                 completed, pending_addr, pending_write, last_data, last_waits, A_HRESP);
      end
      pending = HTRANS[1];
      pending_waits = 0;
      if (pending) begin
        accepted++;
        pending_addr = HADDR;
        pending_write = HWRITE;
        pending_burst = (HBURST == 3'b101);
        if (pending_burst) burst_accepted++;
      end
    end else if (pending) begin
      pending_waits++;
      stalled++;
    end
  end

  task automatic step(input logic [1:0] trans, input logic [55:0] addr,
                      input bit wr, input logic [63:0] wd,
                      input logic [7:0] strb, input bit ready,
                      input logic [63:0] rd, input bit resp);
    @(negedge HCLK);
    A_HTRANS = trans;
    A_HADDR = addr;
    A_HWRITE = wr;
    A_HWDATA = wd;
    A_HWSTRB = strb;
    HREADY = ready;
    HRDATA = rd;
    HRESP = resp;
    // Check propagation BEFORE the next clock edge, not just after it.
    #1;
    check_transparency();
    @(posedge HCLK);
    #1;
  endtask

  initial begin
    $dumpfile("shared_guard.vcd");
    $dumpvars;
    // Reset never masks otherwise nonzero bus values or response signals.
    A_HPROT = 4'hf; A_HMASTLOCK = 1;
    A_HSIZE = 3'd3; A_HBURST = 3'b101;
    step(2'b10, 56'hfedcba98765432, 1, 64'hfedcba9876543210, 8'ha5,
         0, 64'h0123456789abcdef, 1);
    assert (accepted == 0 && completed == 0) else $fatal;
    HRESETn = 1; A_HMASTLOCK = 0; A_HBURST = 0; A_HPROT = 2;
    step(2'b00, 0, 0, 64'h11, 8'hff, 1, 64'h22, 0);
    step(2'b01, 56'h100, 0, 64'h33, 8'h0f, 1, 64'h44, 0);
    assert (accepted == 0 && completed == 0) else $fatal;

    // Read X overlaps Write Y's address, then Y data overlaps Read Z.
    step(2'b10, 56'h100, 0, 0, 0, 1, 0, 0);
    step(2'b10, 56'h200, 1, 0, 0, 1, 64'h123456789abcdef0, 0);
    assert (last_addr == 'h100 && last_data == 64'h123456789abcdef0) else $fatal;
    step(2'b10, 56'h300, 0, 64'hdeadbeefcafef00d, 8'h81, 1, 0, 0);
    assert (last_addr == 'h200 && last_data == 64'hdeadbeefcafef00d && last_strb == 8'h81)
      else $fatal(1, "Write data was masked by current read address");
    step(2'b00, 0, 0, 64'h55, 8'hff, 1, 64'h3333, 0);
    assert (completed == 3 && last_addr == 'h300 && last_data == 'h3333) else $fatal;
    $display("PASS: IDLE/BUSY, read/write overlap, reset transparency");

    // Write data must survive multiple waits while the next address is IDLE.
    step(2'b10, 56'h400, 1, 0, 0, 1, 0, 0);
    repeat (3) step(2'b00, 0, 0, 64'h4444, 8'h0f, 0, 64'h9999, 0);
    assert (completed == 3 && pending_addr == 'h400) else $fatal;
    step(2'b00, 0, 0, 64'h4444, 8'h0f, 1, 0, 0);
    assert (completed == 4 && last_waits == 3 && last_data == 'h4444) else $fatal;

    // Two-cycle error: HRESP must be visible even when HREADY is low.
    step(2'b10, 56'h500, 0, 0, 0, 1, 0, 0);
    step(2'b00, 0, 0, 0, 0, 0, 64'h5555, 1);
    assert (A_HRESP && !A_HREADY && completed == 4) else $fatal;
    step(2'b00, 0, 0, 0, 0, 1, 64'h5555, 1);
    assert (completed == 5 && errors == 1 && last_waits == 1) else $fatal;
    $display("PASS: multi-wait write and two-cycle error response");

    // INCR8 read. Stall beat 2's data phase while beat 3's address waits.
    A_HBURST = 3'b101;
    for (int i = 0; i < 8; i++) begin
      if (i == 3) begin
        repeat (3) step(2'b11, 56'h1000 + 56'(i*8), 0, 0, 0, 0, 64'hbeef, 0);
        assert (burst_accepted == 3 && burst_completed == 2) else $fatal;
      end
      step(i == 0 ? 2'b10 : 2'b11, 56'h1000 + 56'(i*8), 0, 0, 0,
           1, 64'h100 + 64'(i-1), 0);
      if (i == 3) assert (last_addr == 'h1010 && last_waits == 3 && last_data == 'h102) else $fatal;
    end
    A_HBURST = 0;
    step(2'b00, 0, 0, 0, 0, 1, 64'h107, 0);
    assert (burst_accepted == 8 && burst_completed == 8 && last_addr == 'h1038 && last_data == 'h107)
      else $fatal;
    $display("PASS: INCR8 read, middle beat stalled for three wait cycles");

    // INCR8 write. BUSY creates no data phase; keep burst continuity.
    // Write beat 2 stalls with the next address held at beat 3.
    A_HBURST = 3'b101;
    step(2'b10, 56'h2000, 1, 0, 0, 1, 0, 0);
    for (int i = 1; i < 8; i++) begin
      if (i == 3) begin
        repeat (2) step(2'b11, 56'h2000 + 56'(i*8), 1,
                        64'h200 + 64'(i-1), 8'hff, 0, 0, 0);
      end
      step(2'b11, 56'h2000 + 56'(i*8), 1,
           64'h200 + 64'(i-1), 8'hff, 1, 0, 0);
    end
    step(2'b01, 56'h2040, 1, 64'h207, 8'hff, 1, 0, 0);
    assert (burst_accepted == 16 && burst_completed == 16 && last_data == 'h207) else $fatal;
    A_HBURST = 0;
    step(2'b00, 0, 0, 0, 0, 1, 0, 0);
    $display("PASS: INCR8 write, middle beat stalled for two wait cycles");

    // Reset with a pending transfer: no delayed copy may be replayed.
    step(2'b10, 56'h600, 1, 0, 0, 1, 0, 0);
    HRESETn = 0;
    step(2'b00, 0, 0, 64'h6666, 8'hff, 0, 0, 1);
    HRESETn = 1;
    step(2'b00, 0, 0, 64'h7777, 8'hff, 1, 0, 0);
    assert (!pending && completed == 21 && accepted == 22 && reads == 11 && writes == 10
            && errors == 1 && stalled == 9) else $fatal(1, "Final scoreboard mismatch");
    $display("SHARED_GUARD_TEST_PASS accepted=%0d completed=%0d reads=%0d writes=%0d waits=%0d errors=%0d reset_cancelled=1",
             accepted, completed, reads, writes, stalled, errors);
    $finish;
  end
endmodule
