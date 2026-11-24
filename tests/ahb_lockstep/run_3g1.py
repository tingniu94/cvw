"""Build the dual wrapper and exercise the original shared Uncore, not dual CPU execution."""
import argparse
import csv
import hashlib
import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NEW = ['src/wally/wallylockstepsoc.sv', 'tests/ahb_lockstep/uncore_gate_tb.sv', 'tests/ahb_lockstep/wrapper_build_tb.sv', 'tests/ahb_lockstep/run_3g1.py', 'tests/ahb_lockstep/uncore_gate_dpi.cpp']


def dump(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, ensure_ascii=False); stream.write('\n')


def execute(run, name, command, cwd=ROOT):
    dump(run / (name + '-command.json'), {'argv': command, 'cwd': str(cwd), 'env': {'WALLY': str(ROOT), 'RISCV': os.environ.get('RISCV', '/opt/riscv')}})
    print(name, flush=True)
    with (run / (name + '.log')).open('x') as stream:
        result = subprocess.run(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT, env={**os.environ, 'WALLY': str(ROOT), 'RISCV': os.environ.get('RISCV', '/opt/riscv')}, timeout=1800)
    dump(run / (name + '-result.json'), {'returncode': result.returncode})
    if result.returncode:
        raise RuntimeError(f'{name} 失敗, 請查看原始 Log')
    if name.endswith(('-lint', '-build')):
        assert '%Warning' not in (run / (name + '.log')).read_text(), 'New build warnings'


def rtl_sources(tracked):
    # Include the wrapper exactly once before and after it becomes tracked.
    return ['src/cvw.sv'] + sorted(name for name in tracked if name.endswith('.sv') and name not in ('src/cvw.sv', NEW[0])) + [NEW[0]]


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('output', type=Path)
    parser.add_argument('--phase', choices=['gate', 'wrapper', 'single', 'all'], default='all')
    args = parser.parse_args(); run = args.output.resolve()
    run.mkdir(parents=True, exist_ok=False)
    tracked = subprocess.check_output(['git', 'ls-files', 'src'], cwd=ROOT, text=True).splitlines()
    rtl = rtl_sources(tracked)
    assert 'src/ebu/ahb_guard.sv' not in rtl
    snapshot = run / 'source-snapshot'
    support = ['testbench/testbench.sv', 'sim/verilator/Makefile', 'sim/verilator/wrapper.c'] + sorted(str(p.relative_to(ROOT)) for directory, pattern in [('config/rv64gc', '*.vh'), ('config/shared', '*.vh'), ('testbench/common', '*.sv')] for p in (ROOT / directory).glob(pattern))
    for name in rtl + NEW[1:] + support:
        target = snapshot / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes((ROOT / name).read_bytes())
    dump(run / 'source-manifest.json', {'rtl': rtl, 'support': support, 'new_files': NEW, 'excluded_untracked': ['src/ebu/ahb_guard.sv', 'src/ebu/ahb_guard.sv.step1', 'src/wally/wallypipelinedsoc.sv.before_guard']})
    dump(run / 'safety-sha256.json', {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in ['tests/riscof/config.ini', 'docs/meeting-progress-log.md']})
    inputs = run / 'inputs'; inputs.mkdir()
    for suffix in ['', '.memfile', '.objdump', '.objdump.addr', '.objdump.lab']:
        (inputs / ('hello' + suffix)).write_bytes((ROOT / ('examples/C/hello/hello' + suffix)).read_bytes())
    dump(run / 'inputs-sha256.json', {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs.iterdir()})
    dump(run / 'source-sha256.json', {str(p.relative_to(snapshot)): hashlib.sha256(p.read_bytes()).hexdigest() for p in snapshot.rglob('*') if p.is_file()})
    dump(run / 'environment.json', {key: subprocess.check_output(command, cwd=ROOT, text=True).strip() for key, command in {
        'branch': ['git', 'branch', '--show-current'], 'head': ['git', 'rev-parse', 'HEAD'], 'status': ['git', 'status', '--short'], 'verilator': ['verilator', '--version']}.items()})
    common = ['verilator', '--timing', '--assert', '--timescale', '1ps/1ps', '-I' + str(ROOT / 'config/rv64gc'), '-I' + str(ROOT / 'config/shared')]
    results = {'REAL_DUAL_CORE_HELLO': 'Pending', 'full_F2_acceptance_complete': False}
    if args.phase in ('gate', 'all'):
        sources = [str(ROOT / name) for name in rtl + [NEW[1]]]
        base = common + ['--top-module', 'uncore_gate_tb']
        execute(run, 'gate-lint', base + ['--lint-only'] + sources)
        execute(run, 'gate-build', base + ['--binary', '--trace-fst', '--Mdir', str(run / 'work-gate'), str(ROOT / NEW[4])] + sources)
        runtime = run / 'gate'; runtime.mkdir()
        execute(run, 'gate-simulation', [str(run / 'work-gate/Vuncore_gate_tb')], runtime)
        log = (run / 'gate-simulation.log').read_text(); assert 'UNCORE_GATE_PASS' in log
        with (runtime / 'guard-events.csv').open() as stream:
            rows = list(csv.DictReader(stream))
        beats = [row for row in rows if row['down_accept'] == '1']
        dump(runtime / 'transaction-ledger.json', beats)
        results['UNCORE_GATE'] = {'status': 'PASS', 'source': 'SYNTHETIC_AB_WITH_REAL_GUARD_AND_UNCORE', 'result': next(line[line.index('UNCORE_GATE_PASS'):] for line in log.splitlines() if 'UNCORE_GATE_PASS' in line)}
    if args.phase in ('wrapper', 'all'):
        sources = [str(ROOT / name) for name in rtl + [NEW[2]]]
        base = common + ['--top-module', 'wrapper_build_tb']
        execute(run, 'wrapper-lint', base + ['--lint-only'] + sources)
        execute(run, 'wrapper-json', base + ['--json-only', '--json-only-output', str(run / 'wrapper.tree.json')] + sources)
        tree = json.loads((run / 'wrapper.tree.json').read_text())
        nodes = []
        def walk(value):
            if isinstance(value, dict):
                nodes.append(value)
                for child in value.values():
                    walk(child)
            elif isinstance(value, list):
                for child in value:
                    walk(child)
        walk(tree)
        cells = {name: [node for node in nodes if node.get('type') == 'CELL' and node.get('name') == name] for name in ['core', 'core_b', 'lockstep_guard', 'uncore']}
        assert all(len(value) == 1 for value in cells.values()), 'Wrong instance count'
        cells = {name: value[0] for name, value in cells.items()}
        assert cells['core']['modp'] == cells['core_b']['modp'], 'Different CPU configuration'
        definition = next(node for node in nodes if node.get('addr') == cells['core']['modp'])
        assert definition.get('origName') == 'wallypipelinedcore', 'Not original CPU RTL'
        def pins(cell):
            return {pin['name']: pin.get('exprp', [{}])[0].get('name') for pin in cell['pinsp']}
        connections = {name: pins(cell) for name, cell in cells.items()}
        bus = ['HADDR', 'HWDATA', 'HWSTRB', 'HWRITE', 'HSIZE', 'HBURST', 'HPROT', 'HTRANS', 'HMASTLOCK', 'HRDATA', 'HREADY', 'HRESP']
        for instance, tag in [('core', 'A'), ('core_b', 'B')]:
            for signal in bus + ['HCLK', 'HRESETn']:
                assert connections[instance][signal] == tag + '_' + signal
            for signal in bus:
                assert connections['lockstep_guard'][tag + '_' + signal] == tag + '_' + signal
            for signal in ['clk', 'reset', 'MTimerInt', 'MExtInt', 'SExtInt', 'MSwInt', 'MTIME_CLINT', 'ExternalStall']:
                assert connections[instance][signal] == signal
        for signal in bus:
            assert connections['lockstep_guard']['M_' + signal] == signal
            assert connections['uncore'][signal] == signal
        dump(run / 'connection-check.json', {'status': 'PASS', 'cpu_module': definition['origName'], 'connections': connections})
        dump(run / 'elaboration-instances.json', [{key: value for key, value in cell.items() if key != 'pinsp'} for cell in cells.values()])
        make = ['make', '-C', str(ROOT / 'sim/verilator'), 'WALLYCONF=rv64gc', 'TESTBENCH=wrapper_build_tb', 'SOURCES=' + ' '.join(sources),
                'WORKDIR=' + str(run / 'work-wrapper'), 'WRAPPER=' + str(ROOT / NEW[4]), 'VERILATOR_FLAGS=--assert --timing --trace-fst --no-trace-top --stats --timescale 1ps/1ps']
        execute(run, 'wrapper-build', make)
        results['WRAPPER_BUILD'] = {'status': 'PASS', 'cpu_instances': ['core', 'core_b'], 'simulation_executed': False}
    if args.phase in ('single', 'all'):
        # Preserve the original testbench and use a separate runtime/compiled binary.
        testbench = ['testbench/testbench.sv'] + sorted(str(p.relative_to(ROOT)) for p in (ROOT / 'testbench/common').glob('*.sv'))
        ethernet = sorted(str(p.relative_to(ROOT)) for p in (ROOT / 'addins/verilog-ethernet').rglob('*.sv'))
        sources = [str(ROOT / name) for name in rtl + testbench + ethernet]
        command = ['make', '-C', str(ROOT / 'sim/verilator'), 'WALLYCONF=rv64gc', 'TESTBENCH=testbench', 'SOURCES=' + ' '.join(sources), 'WORKDIR=' + str(run / 'work-single'),
                   'VERILATOR_FLAGS=--assert --timing --trace-fst --no-trace-top --stats --timescale 1ps/1ps']
        execute(run, 'single-build', command)
        runtime = run / 'single'; (runtime / 'logs').mkdir(parents=True)
        execute(run, 'single-simulation', [str(run / 'work-single/Vtestbench'), '+TEST=hello_hello', '+ElfFile=' + str(inputs / 'hello'),
             '+AHB_MONITOR_LIMIT=0', '+UART_LOG=1', '+UART_LOG_FILE=logs/uart.out'], runtime)
        assert 'Hello Wally!' in (runtime / 'logs/uart.out').read_text()
        results['SINGLE_CORE_BASELINE'] = 'PASS'
    assert all(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == digest for name, digest in json.loads((run / 'source-sha256.json').read_text()).items()), 'Source changed during run'
    dump(run / 'summary.json', results)
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
