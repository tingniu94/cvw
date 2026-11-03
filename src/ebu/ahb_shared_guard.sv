///////////////////////////////////////////
// A-only shared AHB arbitration / guard boundary.
// Owner is always A and policy is always Allow. No transaction state is
// required: address/control and data may refer to different A transactions.
///////////////////////////////////////////
module ahb_shared_guard #(
  parameter integer ADDR_WIDTH = 56,
  parameter integer DATA_WIDTH = 64,
  parameter integer STRB_WIDTH = DATA_WIDTH / 8
)(
  input  logic                      HCLK, HRESETn,
  // Upstream: the original Core A AHB interface.
  input  logic [ADDR_WIDTH-1:0]     A_HADDR,
  input  logic [DATA_WIDTH-1:0]     A_HWDATA,
  input  logic [STRB_WIDTH-1:0]     A_HWSTRB,
  input  logic                      A_HWRITE,
  input  logic [2:0]                A_HSIZE, A_HBURST,
  input  logic [3:0]                A_HPROT,
  input  logic [1:0]                A_HTRANS,
  input  logic                      A_HMASTLOCK,
  output logic [DATA_WIDTH-1:0]     A_HRDATA,
  output logic                      A_HREADY, A_HRESP,
  // Downstream: the existing shared H* bus and Uncore response.
  output logic [ADDR_WIDTH-1:0]     HADDR,
  output logic [DATA_WIDTH-1:0]     HWDATA,
  output logic [STRB_WIDTH-1:0]     HWSTRB,
  output logic                      HWRITE,
  output logic [2:0]                HSIZE, HBURST,
  output logic [3:0]                HPROT,
  output logic [1:0]                HTRANS,
  output logic                      HMASTLOCK,
  input  logic [DATA_WIDTH-1:0]     HRDATA,
  input  logic                      HREADY, HRESP
);
  // A-only selection is unconditional, including IDLE, BUSY and reset.
  // HCLK/HRESETn retain their original source; neither gates the datapath.
  assign HADDR     = A_HADDR;
  assign HWRITE    = A_HWRITE;
  assign HSIZE     = A_HSIZE;
  assign HBURST    = A_HBURST;
  assign HPROT     = A_HPROT;
  assign HTRANS    = A_HTRANS;
  assign HMASTLOCK = A_HMASTLOCK;

  // Write data belongs to the previous accepted address phase. Never mask
  // it with the current address phase's HWRITE, HTRANS, or HREADY.
  assign HWDATA    = A_HWDATA;
  assign HWSTRB    = A_HWSTRB;

  // Forward the whole response, even during waits, errors and idle cycles.
  assign A_HRDATA  = HRDATA;
  assign A_HREADY  = HREADY;
  assign A_HRESP   = HRESP;
endmodule
