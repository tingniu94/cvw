// Integration smoke test for the existing rv32i BUS_SUPPORTED=0 configuration.
`include "config.vh"
import cvw::*;
module no_bus_tb;
  `include "parameter-defs.vh"
  logic clk = 0, reset_ext = 1, reset;
  logic [P.AHBW-1:0] HRDATAEXT = '1, HWDATA;
  logic HREADYEXT = 1, HRESPEXT = 1, HSELEXT;
  logic ExternalStall = 0, HCLK, HRESETn, HWRITE, HMASTLOCK, HREADY;
  logic [P.PA_BITS-1:0] HADDR;
  logic [P.XLEN/8-1:0] HWSTRB;
  logic [2:0] HSIZE, HBURST;
  logic [3:0] HPROT;
  logic [1:0] HTRANS;
  logic TIMECLK = 0;
  logic [31:0] GPIOIN = '1, GPIOOUT, GPIOEN;
  logic UARTSin = 1, UARTSout, SPIIn = 1, SPIOut, SPICLK;
  logic [3:0] SPICS, SDCCS, PWMGPIO;
  logic SDCIn = 1, SDCCmd, SDCCLK;
  wallypipelinedsoc #(P) dut(.*);
  always #5 clk = ~clk;
  initial begin
    assert (!P.BUS_SUPPORTED) else $fatal(1, "Use rv32i config for this test");
    $dumpfile("no_bus.vcd");
    $dumpvars;
    repeat (4) @(negedge clk);
    reset_ext = 0;
    repeat (12) begin
      @(negedge clk);
      HRDATAEXT = ~HRDATAEXT;
      HREADYEXT = ~HREADYEXT;
      HRESPEXT = ~HRESPEXT;
      #1;
      assert ({HCLK,HRESETn,HADDR,HWDATA,HWSTRB,HWRITE,HSIZE,HBURST,
               HPROT,HTRANS,HMASTLOCK,HREADY,HSELEXT} === '0)
        else $fatal(1, "No-bus shared outputs are not zero");
      assert ({dut.A_HRDATA,dut.A_HREADY,dut.A_HRESP,dut.HRDATA,dut.HRESP} === '0)
        else $fatal(1, "No-bus upstream responses are not connected to zero");
    end
    $display("NO_BUS_TEST_PASS: rv32i BUS_SUPPORTED=0 outputs/responses remain zero");
    $finish;
  end
endmodule
