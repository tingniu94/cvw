"""Build/run the Step 3B tests in a NEW directory, preserving older artifacts.

Usage: python3 tests/ahb_lockstep/run_ingress.py artifacts/ahb-lockstep-step3b/run-002
Requires Verilator and its normal C++ toolchain. Does not run a processor Core.
"""
import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path, help="New output directory; existing directories are rejected")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
run = args.output.resolve()
run.mkdir(parents=True, exist_ok=False)
paths = set()
for directory in ("src", "backups", "docs", "tests/ahb_monitor", "tests/ahb_shared_guard",
                  "artifacts/ahb-shared-guard-step2"):
    for path in (root / directory).rglob("*"):
        if path.is_file() and not any(part.startswith("work-") for part in path.relative_to(root).parts):
            paths.add(path)
for pattern in ("*.vcd", "*.fst", "*.gtkw", "*.log"):
    paths.update((root / "sim").rglob(pattern))
paths.add(root / "tests/riscof/config.ini")
manifest = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(paths)}
(run / "preserved-sha256.json").write_text(json.dumps(manifest, indent=2) + "\n")


def execute(command, log_name, cwd):
    print(log_name, flush=True)
    with (run / log_name).open("x") as output:
        subprocess.run(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT, check=True)


base = ["verilator", "--binary", "--trace", "--timing", "--assert", "--timescale", "1ps/1ps"]
for name, mode in (("unit", None), ("cvw-single", 0), ("cvw-cache", 1)):
    top = "ingress_tb" if mode is None else "ingress_cvw_tb"
    command = base + ["--top-module", top, "--Mdir", str(run / f"work-{name}")]
    if mode is not None:
        command.append(f"-GCACHE_MODE=1'b{mode}")
    command += [str(root / "src/ebu/ahb_lockstep_ingress.sv"),
                str(root / f"tests/ahb_lockstep/{top}.sv")]
    if mode is not None:
        command += [str(root / f"src/ebu/{item}.sv") for item in
                    ("ahbinterface", "busfsm", "buscachefsm")]
        command += [str(root / f"src/generic/flop/{item}.sv") for item in
                    ("flop", "flopen", "flopenr")]
    (run / f"{name}-command.json").write_text(json.dumps(command, indent=2) + "\n")
    execute(command, f"{name}-build.log", root)
    runtime = run / name
    runtime.mkdir()
    execute([str(run / f"work-{name}/V{top}")], f"{name}.log", runtime)
execute([sys.executable, str(root / "tests/ahb_lockstep/summarize_ingress.py"), str(run)],
        "verification.log", root)
print(f"PASS: {run / 'summary.json'}", flush=True)
