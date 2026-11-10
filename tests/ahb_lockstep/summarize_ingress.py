"""Read existing Step 3B logs/CSV and verify preserved artifacts; no simulation.

Usage: python3 summarize_ingress.py RUN_DIRECTORY
Writes summary.json only if it does not already exist.
"""
import csv
import hashlib
import json
import re
import sys
from pathlib import Path

run = Path(sys.argv[1]).resolve()
rows = list(csv.DictReader((run / "unit/ingress-cycles.csv").open()))
counts = {name: sum(int(row[name]) for row in rows) for name in
          ("addr_accept", "data_complete", "req_dispatch", "rsp_capture")}
expected = {"addr_accept": 9, "data_complete": 7, "req_dispatch": 8, "rsp_capture": 7}
if counts != expected:
    raise SystemExit(f"Unexpected per-cycle accounting: {counts}")
pending = None
transactions = []
for row in rows:
    time = int(row["time_ps"])
    if row["resetn"] == "0":
        if pending:
            pending.update(cancelled_ps=time)
            transactions.append(pending)
            pending = None
        continue
    if row["data_complete"] == "1":
        if pending is None:
            raise SystemExit("Completion without pending address")
        pending.update(completed_ps=time, rdata="0x" + row["hrdata"], error=int(row["hresp"]))
        transactions.append(pending)
        pending = None
    if row["addr_accept"] == "1":
        if pending is not None:
            raise SystemExit("Accepted address overwrote a pending transaction")
        pending = {"accepted_ps": time, "addr": "0x" + row["haddr"], "write": int(row["hwrite"])}
    if row["req_dispatch"] == "1":
        if pending is None or "dispatched_ps" in pending:
            raise SystemExit("Duplicate internal request dispatch")
        pending.update(dispatched_ps=time, seq=int(row["seq"]), wdata="0x" + row["req_wdata"],
                       wstrb="0x" + row["req_wstrb"])
    if row["rsp_capture"] == "1":
        if pending is None or "dispatched_ps" not in pending or "response_ps" in pending:
            raise SystemExit("Unexpected internal response")
        pending.update(response_ps=time)
if pending is not None:
    raise SystemExit("Pending transaction left after test")
if "INGRESS_TEST_PASS" not in (run / "unit.log").read_text():
    raise SystemExit("Unit test did not pass")
for name, marker in (("cvw-single", "mode=0 accepted=2 dispatched=2 completed=2 cache_ack=0"),
                     ("cvw-cache", "mode=1 accepted=8 dispatched=8 completed=8 cache_ack=1")):
    # Early failed attempts are preserved; final successful logs take priority.
    path = run / f"{name}-final.log"
    if not path.exists():
        path = run / f"{name}.log"
    if "CVW_INGRESS_TEST_PASS " + marker not in path.read_text():
        raise SystemExit(f"Controller compatibility test failed: {path}")
for name in ("unit", "cvw-single", "cvw-cache"):
    candidates = [run / f"{name}-build{suffix}.log" for suffix in ("-typed", "-final", "")]
    path = next(path for path in candidates if path.exists())
    if re.search(r"%Warning|%Error|warning:|error:", path.read_text()):
        raise SystemExit(f"Final build has warnings/errors: {path}")
manifest = json.loads((run / "preserved-sha256.json").read_text())
for filename, digest in manifest.items():
    if hashlib.sha256(Path(filename).read_bytes()).hexdigest() != digest:
        raise SystemExit(f"Preserved file changed: {filename}")
summary = {"status": "PASS", "baseline_commit": "8ff5bf2471d51e45a3317768e04aac4bb97d3ee0",
           "cycle_rows": len(rows), "per_cycle_counts": counts,
           "reset_cancelled": sum("cancelled_ps" in item for item in transactions),
           "unit_transactions": transactions, "cvw_single": "PASS", "cvw_cache": "PASS",
           "final_build_warnings": 0, "preserved_files_unchanged": len(manifest)}
with (run / "summary.json").open("x") as output:
    output.write(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
