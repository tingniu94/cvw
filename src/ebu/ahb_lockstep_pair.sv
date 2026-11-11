// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Ordered ready/valid join. Storage remains in the two Step 3B ingress slots.
// No payload comparison, issue authorization, or external AHB master.
module ahb_lockstep_pair #(
  parameter integer REQ_WIDTH = 174,
  parameter integer SEQ_WIDTH = 32
)(
  input  logic HCLK, HRESETn,
  input  logic a_req_valid, b_req_valid,
  output logic a_req_ready, b_req_ready,
  input  logic [REQ_WIDTH-1:0] a_req_payload, b_req_payload,
  output logic pair_valid,
  input  logic pair_ready,
  output logic [REQ_WIDTH-1:0] pair_a_payload, pair_b_payload,
  output logic [SEQ_WIDTH-1:0] pair_seq,
  output logic [63:0] paired_requests,
  output logic [63:0] pairing_wait_cycles, a_peer_wait_cycles, b_peer_wait_cycles,
  output logic [63:0] pair_backpressure_cycles
);
  assign pair_valid = HRESETn && a_req_valid && b_req_valid;
  assign a_req_ready = HRESETn && pair_ready && b_req_valid;
  assign b_req_ready = HRESETn && pair_ready && a_req_valid;
  assign pair_a_payload = a_req_payload;
  assign pair_b_payload = b_req_payload;

  // Pre-edge XOR of complete OFFERs counts peer wait, including the edge
  // capturing a late peer address/data. Both-valid consumer stalls are separate.
  // Counters reset with the ingresses; unsigned modulo-2^64, no timeout action.
  always_ff @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) begin
      pair_seq <= '0;
      paired_requests <= '0;
      pairing_wait_cycles <= '0;
      a_peer_wait_cycles <= '0;
      b_peer_wait_cycles <= '0;
      pair_backpressure_cycles <= '0;
    end else begin
      if (a_req_valid && !b_req_valid) begin
        pairing_wait_cycles <= pairing_wait_cycles + 64'd1;
        a_peer_wait_cycles <= a_peer_wait_cycles + 64'd1;
      end
      if (b_req_valid && !a_req_valid) begin
        pairing_wait_cycles <= pairing_wait_cycles + 64'd1;
        b_peer_wait_cycles <= b_peer_wait_cycles + 64'd1;
      end
      if (pair_valid && !pair_ready)
        pair_backpressure_cycles <= pair_backpressure_cycles + 64'd1;
      if (pair_valid && pair_ready) begin
        pair_seq <= pair_seq + 1'b1;
        paired_requests <= paired_requests + 64'd1;
      end
    end
  end
endmodule
