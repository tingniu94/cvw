module monitor_tb;
  logic HCLK=0, HRESETn=0;
  logic [31:0] HADDR=0, HWDATA=0, HRDATA=0;
  logic [3:0] HWSTRB=0, HPROT=0;
  logic HWRITE=0, HMASTLOCK=0, HREADY=1, HRESP=0;
  logic [2:0] HSIZE=2, HBURST=0;
  logic [1:0] HTRANS=0;
  ahb_monitor #(.ADDR_WIDTH(32),.DATA_WIDTH(32),.STRB_WIDTH(4)) dut(.*);
  always #5 HCLK=~HCLK;
  task automatic tick;
    @(posedge HCLK); #1; @(negedge HCLK);
  endtask
  initial begin
    tick(); HRESETn=1;
    // Read address, followed by a write address while the read completes.
    HADDR='h100; HTRANS=2; tick();
    assert(dut.pending && dut.addr_q=='h100 && dut.completed==0) else $fatal;
    HADDR='h200; HWRITE=1; HRDATA='h12345678; tick();
    assert(dut.completed==1 && dut.addr_q=='h200 && dut.write_q) else $fatal;
    // Two stalled data cycles: changing address must not replace metadata.
    HREADY=0; HADDR='hbad; HTRANS=0; HWDATA='hdeadbeef; HWSTRB=5;
    tick(); tick();
    assert(dut.completed==1 && dut.addr_q=='h200 && dut.wait_cycles==2) else $fatal;
    HREADY=1; HTRANS=1; tick(); // BUSY must not become a new transaction.
    assert(dut.completed==2 && !dut.pending) else $fatal;
    tick(); HTRANS=0; tick();
    assert(dut.completed==2) else $fatal;
    // Two-cycle error response: log only the completing data phase.
    HADDR='h300; HWRITE=0; HTRANS=2; tick();
    HTRANS=0; HREADY=0; HRESP=1; tick();
    assert(dut.completed==2 && dut.pending) else $fatal;
    HREADY=1; HRDATA='hffffffff; tick();
    assert(dut.completed==3 && !dut.pending) else $fatal;
    // Reset cancels a pending address; it must never produce a completion.
    HRESP=0; HADDR='h400; HTRANS=2; tick();
    HRESETn=0; HTRANS=0; tick(); HRESETn=1; tick();
    assert(dut.completed==0 && !dut.pending) else $fatal;
    $display("MONITOR_TEST_PASS: overlap, stalls, IDLE/BUSY, error, reset");
    $finish;
  end
endmodule
