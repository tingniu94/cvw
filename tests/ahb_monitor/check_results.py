"""Check extracted baseline/monitor waveforms and completed-beat logs.

Usage: python3 check_results.py VALIDATION_DIRECTORY
The directory contains baseline/, monitor/, baseline.log and monitor.log.
"""
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
for name in ("bus-events.txt", "transactions.json", "summary.json"):
    assert (root / "baseline" / name).read_bytes() == (root / "monitor" / name).read_bytes(), name
print("PASS: all observed AHB transitions, timestamps and transactions match")
transactions = json.loads((root / "baseline/transactions.json").read_text())
log = (root / "monitor.log").read_text()
records = re.findall(r"\[AHB_MON\] ([^\n]*)", log)
assert len(records) == len(transactions)
for index, (record, transaction) in enumerate(zip(records, transactions)):
    fields = dict(re.findall(r"(\w+)=(\w+)", record))
    for key in ("addr_cycle", "done_cycle", "waits", "write", "size", "burst"):
        assert int(fields[key]) == transaction[key], (index, key)
    for key in ("addr", "prot", "resp", "lock"):
        assert int(fields[key], 16) == transaction[key], (index, key)
    assert int(fields["trans"], 2) == transaction["trans"], index
    data_key = "wdata" if transaction["write"] else "rdata"
    assert int(fields[data_key], 16) == transaction["data"], index
    if transaction["write"]:
        assert int(fields["strb"], 16) == transaction["strb"], index
    assert int(fields["beat"]) == index, index
print(f"PASS: {len(records)} monitor records match independent baseline decoding")
for name in ("baseline", "monitor"):
    text = (root / f"{name}.log").read_text()
    text = re.sub(r"\[AHB_MON\] [^\n]*\n", "", text)
    assert "Hello Wally!" in text, name
    assert "0 1 2 3 4 5 6 7 8 9" in text, name
print("PASS: Hello Wally and 0-9 output match")
