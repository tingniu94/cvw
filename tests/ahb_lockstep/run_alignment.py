"""Step 3C synthetic join tests + unmodified Step 3B regression in a new directory.

Usage: python3 tests/ahb_lockstep/run_alignment.py NEW_OUTPUT_DIRECTORY
"""
import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def dump(path, data):
    with path.open('x') as output:
        json.dump(data, output, indent=2)
        output.write('\n')


def execute(run, name, command, cwd):
    dump(run / (name + '-command.json'), {'argv': command, 'cwd': str(cwd)})
    print(name, flush=True)
    with (run / (name + '.log')).open('x') as output:
        result = subprocess.run(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT,
                                timeout=300)
    dump(run / (name + '-result.json'), {'returncode': result.returncode})
    if result.returncode:
        raise SystemExit(f'FAIL: {name}, inspect {run / (name + ".log")}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    run = args.output.resolve()
    run.mkdir(parents=True, exist_ok=False)
    dump(run / 'toolchain.json', {name: subprocess.check_output(command, text=True).strip()
                                for name, command in {
                                    'verilator': ['verilator', '--version'],
                                    'head': ['git', 'rev-parse', 'HEAD'],
                                    'branch': ['git', 'branch', '--show-current'],
                                }.items()})
    files = [ROOT / 'src/ebu' / name for name in
             ('ahb_lockstep_ingress.sv', 'ahb_lockstep_pair.sv', 'ahb_lockstep_dual_ingress.sv')]
    files += [ROOT / 'tests/ahb_lockstep' / name for name in
              ('alignment_tb.sv', 'run_alignment.py', 'summarize_alignment.py')]
    snapshot = run / 'source-snapshot'
    snapshot.mkdir()
    hashes = {}
    for path in files:
        (snapshot / path.name).write_bytes(path.read_bytes())
        hashes[str(path.relative_to(ROOT))] = hashlib.sha256(path.read_bytes()).hexdigest()
    dump(run / 'source-sha256.json', hashes)
    base = ['verilator', '--binary', '--trace', '--timing', '--assert', '--timescale', '1ps/1ps']
    command = base + ['--top-module', 'alignment_tb', '--Mdir', str(run / 'work-alignment')]
    command += [str(path) for path in files[:4]]
    execute(run, 'alignment-build', command, ROOT)
    runtime = run / 'unit'
    runtime.mkdir()
    execute(run, 'alignment-simulation', [str(run / 'work-alignment/Valignment_tb')], runtime)
    command = ['verilator', '--lint-only', '--timing', '--assert', '--top-module',
               'ahb_lockstep_dual_ingress', '-GADDR_WIDTH=32', '-GDATA_WIDTH=32',
               '-GSTRB_WIDTH=4', '-GSEQ_WIDTH=8'] + [str(p) for p in files[:3]]
    execute(run, 'lint-32', command, ROOT)
    execute(run, 'step3b-regression', [sys.executable,
            str(ROOT / 'tests/ahb_lockstep/run_ingress.py'), str(run / 'step3b-regression')], ROOT)
    execute(run, 'verification', [sys.executable,
            str(ROOT / 'tests/ahb_lockstep/summarize_alignment.py'), str(run)], ROOT)
    print('STEP3C_PASS', run / 'summary.json', flush=True)


if __name__ == '__main__':
    main()
