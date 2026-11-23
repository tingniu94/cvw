// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Prove that two identical illegal payloads MATCH in the real Comparator,
// but are blocked by the F1 validator. No synthetic match shortcut.
module burst_context_compare_tb;
logic clk=0,resetn=0,pv=0,pr,mv,mr,cf,vf,auth,reject;
logic [10:0] cr;
logic [8:0] vr;
logic [55:0] saved_addr;
logic saved_write,saved_lock;
logic [2:0] saved_size,saved_burst;
logic [1:0] saved_trans;
logic [3:0] saved_prot;
always #5 clk=~clk;
ahb_lockstep_compare cmp(
.HCLK(clk),
.HRESETn(resetn),
.pair_valid(pv),
.pair_ready(pr),
.pair_seq(32'b0),
.match_valid(mv),
.match_ready(mr),
.fault_valid(cf),
.fault_reason(cr),
.pair_a_seq(32'b0),
.pair_a_addr(56'd1016),
.pair_a_write(1'b0),
.pair_a_size(3'd3),
.pair_a_burst(3'd5),
.pair_a_prot(4'd3),
.pair_a_trans(2'd2),
.pair_a_lock(1'b0),
.pair_a_wdata(64'b0),
.pair_a_wstrb(8'b0),
.pair_b_seq(32'b0),
.pair_b_addr(56'd1016),
.pair_b_write(1'b0),
.pair_b_size(3'd3),
.pair_b_burst(3'd5),
.pair_b_prot(4'd3),
.pair_b_trans(2'd2),
.pair_b_lock(1'b0),
.pair_b_wdata(64'b0),
.pair_b_wstrb(8'b0),
.result_seq(),
.saved_a_seq(),
.saved_a_addr(saved_addr),
.saved_a_write(saved_write),
.saved_a_size(saved_size),
.saved_a_burst(saved_burst),
.saved_a_prot(saved_prot),
.saved_a_trans(saved_trans),
.saved_a_lock(saved_lock),
.saved_a_wdata(),
.saved_a_wstrb(),
.saved_b_seq(),
.saved_b_addr(),
.saved_b_write(),
.saved_b_size(),
.saved_b_burst(),
.saved_b_prot(),
.saved_b_trans(),
.saved_b_lock(),
.saved_b_wdata(),
.saved_b_wstrb());
ahb_lockstep_burst_context #(.ENABLE_INCR8(1)) val(
.HCLK(clk),.HRESETn(resetn),.cmd_valid(mv),.consumer_ready(1'b1),.cmd_ready(mr),
.authorized(auth),.rejected(reject),.cmd_addr(saved_addr),.cmd_write(saved_write),
.cmd_lock(saved_lock),.cmd_size(saved_size),.cmd_burst(saved_burst),.cmd_trans(saved_trans),
.cmd_prot(saved_prot),.down_accept(1'b0),.down_complete(1'b0),.end_burst(1'b0),
.compare_fault(cf),.fault(vf),.fault_reason(vr),.burst_active(),.beat_pending(),
.waiting_data(),.beat_index(),.accepted_count(),.completed_count(),.expected_addr());
initial begin
$dumpfile("compare-validator.fst");$dumpvars(0,burst_context_compare_tb);
@(negedge clk); resetn=1;pv=1;
@(posedge clk);#1;
assert(mv&&!cf&&reject&&!auth) else $fatal(1,"identical malformed request did not MATCH then reject");
@(negedge clk);pv=0;
@(posedge clk);#1;
assert(vf&&vr[2]&&!auth) else $fatal(1,"boundary error bypassed validator");
$display("F1_PASS identical_AB_MATCH_blocked_by_validator");$finish;
end
endmodule
