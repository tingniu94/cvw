///////////////////////////////////////////
// Single-side AHB ingress: one pending data phase, no external bus master.
// Empty credit is independent of HTRANS. Saved requests and responses use
// internal ready/valid handshakes; reset must also flush the response producer.
///////////////////////////////////////////
module ahb_lockstep_ingress #(
  parameter integer ADDR_WIDTH = 56,
  parameter integer DATA_WIDTH = 64,
  parameter integer STRB_WIDTH = DATA_WIDTH / 8,
  parameter integer SEQ_WIDTH = 32
)(
  input  logic                      HCLK, HRESETn,
  input  logic [ADDR_WIDTH-1:0]     HADDR,
  input  logic [DATA_WIDTH-1:0]     HWDATA,
  input  logic [STRB_WIDTH-1:0]     HWSTRB,
  input  logic                      HWRITE,
  input  logic [2:0]                HSIZE, HBURST,
  input  logic [3:0]                HPROT,
  input  logic [1:0]                HTRANS,
  input  logic                      HMASTLOCK,
  output logic [DATA_WIDTH-1:0]     HRDATA,
  output logic                      HREADY, HRESP,
  // Internal saved-request port, not another Core-facing bus protocol.
  output logic                      pending_valid, req_valid,
  input  logic                      req_ready,
  output logic [SEQ_WIDTH-1:0]      req_seq,
  output logic [ADDR_WIDTH-1:0]     req_addr,
  output logic                      req_write,
  output logic [2:0]                req_size, req_burst,
  output logic [3:0]                req_prot,
  output logic [1:0]                req_trans,
  output logic                      req_lock,
  output logic [DATA_WIDTH-1:0]     req_wdata,
  output logic [STRB_WIDTH-1:0]     req_wstrb,
  // Exactly one response per request handshake, in order. Both sides reset.
  input  logic                      rsp_valid,
  output logic                      rsp_ready,
  input  logic [DATA_WIDTH-1:0]     rsp_rdata,
  input  logic                      rsp_resp
);
  typedef enum logic [2:0] {
    EMPTY, CAPTURE_DATA, OFFER, WAIT_RESPONSE, RELEASE_OK, ERROR_1, ERROR_2
  } state_t;
  state_t state;
  logic [SEQ_WIDTH-1:0] next_seq;
  logic [DATA_WIDTH-1:0] rsp_data_q;

  assign HREADY = HRESETn &&
                  ((state == EMPTY) || (state == RELEASE_OK) || (state == ERROR_2));
  assign HRESP = HRESETn && ((state == ERROR_1) || (state == ERROR_2));
  assign HRDATA = rsp_data_q;
  assign pending_valid = HRESETn && (state != EMPTY);
  assign req_valid = HRESETn && (state == OFFER);
  assign rsp_ready = HRESETn && (state == WAIT_RESPONSE);

  always_ff @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) begin
      state <= EMPTY;
      next_seq <= '0;
      req_seq <= '0;
      req_addr <= '0;
      req_write <= 1'b0;
      req_size <= '0;
      req_burst <= '0;
      req_prot <= '0;
      req_trans <= '0;
      req_lock <= 1'b0;
      req_wdata <= '0;
      req_wstrb <= '0;
      rsp_data_q <= '0;
    end else begin
      case (state)
        EMPTY, RELEASE_OK, ERROR_2: begin
          // On a release edge the OLD data phase completes while a NEXT
          // address may be accepted. Do not discard that pipelined address.
          if (HTRANS[1]) begin
            req_addr <= HADDR;
            req_write <= HWRITE;
            req_size <= HSIZE;
            req_burst <= HBURST;
            req_prot <= HPROT;
            req_trans <= HTRANS;
            req_lock <= HMASTLOCK;
            req_seq <= next_seq;
            next_seq <= next_seq + 1'b1;
            req_wdata <= '0;
            req_wstrb <= '0;
            state <= HWRITE ? CAPTURE_DATA : OFFER;
          end else state <= EMPTY;
        end
        CAPTURE_DATA: begin
          // The preceding write address was accepted. Capture its stalled
          // data exactly once, regardless of CURRENT HWRITE or HTRANS.
          req_wdata <= HWDATA;
          req_wstrb <= HWSTRB;
          state <= OFFER;
        end
        OFFER: begin
          if (req_ready) state <= WAIT_RESPONSE;
        end
        WAIT_RESPONSE: begin
          if (rsp_valid) begin
            rsp_data_q <= rsp_rdata;
            state <= rsp_resp ? ERROR_1 : RELEASE_OK;
          end
        end
        ERROR_1: state <= ERROR_2;
        default: state <= EMPTY;
      endcase
    end
  end
endmodule
