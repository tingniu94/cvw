"""Step 3D width/bit sweeps, real-ingress synthetic integration, and B/C regression.

Usage: python3 tests/ahb_lockstep/run_compare.py NEW_DIRECTORY
"""
import argparse
import hashlib
import subprocess
import sys
from pathlib import Path

from run_alignment import dump, execute

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    run = args.output.resolve()
    run.mkdir(parents=True, exist_ok=False)
    dump(run / 'toolchain.json', {name: subprocess.check_output(cmd, text=True).strip()
                                 for name, cmd in {
                                     'verilator': ['verilator', '--version'],
                                     'head': ['git', 'rev-parse', 'HEAD'],
                                     'branch': ['git', 'branch', '--show-current'],
                                 }.items()})
    names = ['src/ebu/ahb_lockstep_compare.sv', 'tests/ahb_lockstep/compare_tb.sv',
             'tests/ahb_lockstep/compare_ingress_tb.sv', 'tests/ahb_lockstep/run_compare.py',
             'tests/ahb_lockstep/summarize_compare.py', 'src/ebu/ahb_lockstep_ingress.sv',
             'src/ebu/ahb_lockstep_pair.sv', 'src/ebu/ahb_lockstep_dual_ingress.sv']
    snapshot = run / 'source-snapshot'
    snapshot.mkdir()
    for name in names:
        (snapshot / Path(name).name).write_bytes((ROOT / name).read_bytes())
    dump(run / 'source-sha256.json', {n: hashlib.sha256((ROOT / n).read_bytes()).hexdigest()
                                    for n in names})
    matrix = {'rv64': [56, 64, 8, 32], 'rv32': [34, 32, 4, 32], 'explicit32': [32, 32, 4, 8]}
    dump(run / 'width-matrix.json', matrix)
    for name, widths in matrix.items():
        command = ['verilator', '--binary', '--timing', '--trace', '--assert',
                   '--timescale', '1ps/1ps', '--top-module', 'compare_tb',
                   '--Mdir', str(run / ('work-' + name))]
        command += [f'-G{key}={width}' for key, width in zip(('AW', 'DW', 'SW', 'QW'), widths)]
        command += [str(ROOT / n) for n in names[:2]]
        execute(run, name + '-build', command, ROOT)
        runtime = run / name
        runtime.mkdir()
        execute(run, name + '-simulation', [str(run / ('work-' + name) / 'Vcompare_tb')], runtime)
    command = ['verilator', '--binary', '--timing', '--trace', '--assert',
               '--timescale', '1ps/1ps', '--top-module', 'compare_ingress_tb',
               '--Mdir', str(run / 'work-integration')]
    command += [str(ROOT / n) for n in [*names[5:8], names[0], names[2]]]
    execute(run, 'integration-build', command, ROOT)
    runtime = run / 'integration'
    runtime.mkdir()
    execute(run, 'integration-simulation', [str(run / 'work-integration/Vcompare_ingress_tb')], runtime)
    execute(run, 'step3c-regression', [sys.executable,
            str(ROOT / 'tests/ahb_lockstep/run_alignment.py'), str(run / 'step3c-regression')], ROOT)
    execute(run, 'verification', [sys.executable,
            str(ROOT / 'tests/ahb_lockstep/summarize_compare.py'), str(run)], ROOT)
    print('STEP3D_PASS', run / 'summary.json', flush=True)


if __name__ == '__main__':
    main()
