"""Compare a Step 2 run against the preserved Step 1 AHB baseline.

Usage: python3 verify_step2.py BASELINE_DIRECTORY STEP2_RUN_DIRECTORY
Run extract_bus.py into STEP2_RUN_DIRECTORY/hello-decoded first.
No simulation is run and no baseline files are written.
"""
import hashlib
import json
import re
import sys
from pathlib import Path

baseline = Path(sys.argv[1])
run = Path(sys.argv[2])
for name in ("bus-events.txt", "transactions.json", "summary.json"):
    if (baseline / name).read_bytes() != (run / "hello-decoded" / name).read_bytes():
        raise SystemExit(f"FAIL: Step 1/2 differ: {name}")
transactions = json.loads((baseline / "transactions.json").read_text())
log = (run / "hello.log").read_text()
records = re.findall(r"\[AHB_MON\] ([^\n]*)", log)
if len(records) != len(transactions):
    raise SystemExit("FAIL: Monitor record count differs")
for index, (record, transaction) in enumerate(zip(records, transactions)):
    fields = dict(re.findall(r"(\w+)=(\w+)", record))
    expected = {"beat": index}
    expected.update({key: transaction[key] for key in
                     ("addr_cycle", "done_cycle", "waits", "write", "size", "burst")})
    for key, value in expected.items():
        if int(fields[key]) != value:
            raise SystemExit(f"FAIL: record {index}: {key}")
    for key in ("addr", "prot", "lock", "resp"):
        if int(fields[key], 16) != transaction[key]:
            raise SystemExit(f"FAIL: record {index}: {key}")
    if int(fields["trans"], 2) != transaction["trans"]:
        raise SystemExit(f"FAIL: record {index}: trans")
    key = "wdata" if transaction["write"] else "rdata"
    if int(fields[key], 16) != transaction["data"]:
        raise SystemExit(f"FAIL: record {index}: data")
    if transaction["write"] and int(fields["strb"], 16) != transaction["strb"]:
        raise SystemExit(f"FAIL: record {index}: strb")
text = re.sub(r"\[AHB_MON\] [^\n]*\n", "", log)
if "Hello Wally!" not in text or "0 1 2 3 4 5 6 7 8 9" not in text:
    raise SystemExit("FAIL: Hello Wally output differs")
for filename, success in (("unit.log", "SHARED_GUARD_TEST_PASS"),
                          ("no-bus.log", "NO_BUS_TEST_PASS")):
    if success not in (run / filename).read_text():
        raise SystemExit(f"FAIL: missing success marker: {filename}")
preserved = json.loads((run / "preserved-sha256.json").read_text())
for filename, digest in preserved.items():
    if hashlib.sha256(Path(filename).read_bytes()).hexdigest() != digest:
        raise SystemExit(f"FAIL: preserved artifact changed: {filename}")
logs = ("unit-build.log", "hello-build.log", "no-bus-build-final.log",
        "lint-rv32i.log", "lint-rv32e.log")
for name in logs:
    if re.search(r"%Warning|%Error|warning:|error:", (run / name).read_text()):
        raise SystemExit(f"FAIL: build/lint warning or error: {name}")
summary = json.loads((baseline / "summary.json").read_text())
result = {
    "status": "PASS",
    "baseline_commit": "aebe53d12a1003791bd8f3d8823635aaa3d0330e",
    "all_14_ahb_signals_and_timestamps_identical": True,
    "monitor_records_matched": len(records),
    "preserved_files_unchanged": len(preserved),
    "unit_test": "PASS",
    "no_bus_rv32i_smoke": "PASS",
    "rv32i_rv32e_lint": "PASS",
    "warnings": 0,
    "baseline_and_step2_summary": summary,
}
with (run / "comparison.json").open("x") as output:
    output.write(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
