"""Step 3E SINGLE output/response tests in a new directory, then B/C/D regression."""
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
    dump(run / 'toolchain.json', {k: subprocess.check_output(v, text=True).strip() for k, v in {
        'verilator': ['verilator', '--version'], 'head': ['git', 'rev-parse', 'HEAD'],
        'branch': ['git', 'branch', '--show-current']}.items()})
    sources = ['src/ebu/' + n + '.sv' for n in ['ahb_lockstep_ingress', 'ahb_lockstep_pair',
        'ahb_lockstep_dual_ingress', 'ahb_lockstep_compare', 'ahb_lockstep_output', 'ahb_lockstep_guard']]
    files = sources + ['tests/ahb_lockstep/' + n for n in ['guard_tb.sv', 'output_fork_tb.sv',
                                                                       'run_guard.py', 'summarize_guard.py']]
    snapshot = run / 'source-snapshot'
    snapshot.mkdir()
    for n in files:
        (snapshot / Path(n).name).write_bytes((ROOT / n).read_bytes())
    dump(run / 'source-sha256.json', {n: hashlib.sha256((ROOT / n).read_bytes()).hexdigest() for n in files})
    matrix = {'rv64': [56, 64, 8], 'rv32': [34, 32, 4], 'explicit32': [32, 32, 4]}
    dump(run / 'width-matrix.json', matrix)
    base = ['verilator', '--binary', '--trace', '--timing', '--assert', '--timescale', '1ps/1ps']
    for name, widths in matrix.items():
        cmd = base + ['--top-module', 'guard_tb', '--Mdir', str(run / ('work-' + name))]
        cmd += [f'-G{k}={v}' for k, v in zip(['AW', 'DW', 'SW'], widths)]
        cmd += [str(ROOT / n) for n in sources + ['tests/ahb_lockstep/guard_tb.sv']]
        execute(run, name + '-build', cmd, ROOT)
        runtime = run / name
        runtime.mkdir()
        execute(run, name + '-simulation', [str(run / ('work-' + name) / 'Vguard_tb')], runtime)
    cmd = base + ['--top-module', 'output_fork_tb', '--Mdir', str(run / 'work-fork'),
                  str(ROOT / 'src/ebu/ahb_lockstep_output.sv'),
                  str(ROOT / 'tests/ahb_lockstep/output_fork_tb.sv')]
    execute(run, 'fork-build', cmd, ROOT)
    runtime = run / 'fork'
    runtime.mkdir()
    execute(run, 'fork-simulation', [str(run / 'work-fork/Voutput_fork_tb')], runtime)
    execute(run, 'step3d-regression', [sys.executable, str(ROOT / 'tests/ahb_lockstep/run_compare.py'),
                                     str(run / 'step3d-regression')], ROOT)
    execute(run, 'verification', [sys.executable, str(ROOT / 'tests/ahb_lockstep/summarize_guard.py'), str(run)], ROOT)
    print('STEP3E_PASS', run / 'summary.json', flush=True)


if __name__ == '__main__':
    main()
