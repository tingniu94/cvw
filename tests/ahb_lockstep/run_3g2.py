"""Run the real dual-core Hello wrapper with the original testbench loader."""
import argparse
import csv
import hashlib
import json
import subprocess
from pathlib import Path

from run_3g1 import ROOT, dump, execute, rtl_sources


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('output', type=Path)
    args = parser.parse_args(); run = args.output.resolve(); run.mkdir(parents=True, exist_ok=False)
    rtl = rtl_sources(subprocess.check_output(['git', 'ls-files', 'src'], cwd=ROOT, text=True).splitlines())
    bench = ['testbench/testbench.sv'] + sorted(str(p.relative_to(ROOT)) for p in (ROOT / 'testbench/common').glob('*.sv'))
    ethernet = sorted(str(p.relative_to(ROOT)) for p in (ROOT / 'addins/verilog-ethernet').rglob('*.sv'))
    sources = rtl + bench + ethernet
    files = sources + ['testbench/common/dualcore_monitor.svh', 'tests/ahb_lockstep/run_3g2.py', 'sim/verilator/Makefile', 'sim/verilator/wrapper.c']
    files += sorted(str(p.relative_to(ROOT)) for folder in ['config/rv64gc', 'config/shared'] for p in (ROOT / folder).glob('*.vh'))
    snapshot = run / 'source-snapshot'
    for name in files:
        target = snapshot / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes((ROOT / name).read_bytes())
    dump(run / 'source-sha256.json', {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in files})
    dump(run / 'source-manifest.json', sources)
    dump(run / 'environment.json', {key: subprocess.check_output(command, cwd=ROOT, text=True).strip() for key, command in {
        'head': ['git', 'rev-parse', 'HEAD'], 'branch': ['git', 'branch', '--show-current'], 'status': ['git', 'status', '--short'], 'verilator': ['verilator', '--version']}.items()})
    dump(run / 'safety-sha256.json', {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in ['tests/riscof/config.ini', 'tests/ahb_lockstep/fault_config.ini', 'docs/meeting-progress-log.md']})
    inputs = run / 'inputs'; inputs.mkdir()
    for suffix in ['', '.memfile', '.objdump', '.objdump.addr', '.objdump.lab']:
        (inputs / ('hello' + suffix)).write_bytes((ROOT / ('examples/C/hello/hello' + suffix)).read_bytes())
    dump(run / 'inputs-sha256.json', {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs.iterdir()})
    symbol_text = subprocess.check_output(['riscv64-unknown-elf-nm', '-n', str(inputs / 'hello')], text=True)
    (run / 'elf-symbols.txt').write_text(symbol_text)
    symbols = [int(line.split()[0], 16) for line in symbol_text.splitlines() if len(line.split()) == 3 and line.split()[2] == 'tohost']
    assert len(symbols) == 1 and symbols[0] != 0, 'ELF tohost symbol missing/ambiguous'
    dump(run / 'termination-symbol.json', {'tohost': hex(symbols[0]), 'source': 'frozen ELF data symbol'})
    paths = [str(ROOT / name) for name in sources]
    lint = ['verilator', '--lint-only', '--timing', '--assert', '--relative-includes', '--timescale', '1ps/1ps', '--top-module', 'testbench',
            '-I' + str(ROOT / 'config/rv64gc'), '-I' + str(ROOT / 'config/shared'), '+define+CVW_DUAL_CORE', '-GMAKE_VCD=1'] + paths
    execute(run, 'dual-lint', lint)
    command = ['make', '-C', str(ROOT / 'sim/verilator'), 'WALLYCONF=rv64gc', 'TESTBENCH=testbench',
               'SOURCES=' + ' '.join(paths), 'DEFINE_ARGS=+define+CVW_DUAL_CORE', 'PARAM_ARGS=MAKE_VCD=1', 'WORKDIR=' + str(run / 'work-dual'),
               'VERILATOR_FLAGS=--assert --timing --trace-fst --no-trace-top --stats --timescale 1ps/1ps']
    execute(run, 'dual-build', command)
    runtime = run / 'dual'; (runtime / 'logs').mkdir(parents=True)
    execute(run, 'dual-simulation', [str(run / 'work-dual/Vtestbench'), '+TEST=hello_hello', '+ElfFile=' + str(inputs / 'hello'),
             '+DUAL_TOHOST=' + format(symbols[0], 'x'), '+AHB_MONITOR_LIMIT=0', '+UART_LOG=1', '+UART_LOG_FILE=logs/uart.out'], runtime)
    result = json.loads((runtime / 'dual-result.json').read_text()); assert result['status'] == 'PASS'
    uart = (runtime / 'logs/uart.out').read_bytes(); assert uart == b'Hello Wally!\n\r0 1 2 3 4 5 6 7 8 9 \n\r'
    with (runtime / 'retirement.csv').open() as stream:
        retired = list(csv.DictReader(stream))
    a = [(row['pc'], row['instruction']) for row in retired if row['side'] == '0']
    b = [(row['pc'], row['instruction']) for row in retired if row['side'] == '1']
    assert a == b and len(a) == result['a_retired'] == result['b_retired']
    assert result['a_done'] == result['b_done'] == 1
    for name, digest in json.loads((run / 'source-sha256.json').read_text()).items():
        assert hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == digest, 'Source changed'
    dump(run / 'summary.json', {'DUAL_WRAPPER_RUNTIME_PASS': True, 'DUAL_CORE_FETCH_PASS': True, 'DUAL_CORE_RETIRE_PASS': True,
        'GUARD_REAL_AHB_MATCH_PASS': True, 'DUAL_CORE_HELLO_PASS': True, 'result': result, 'retirement_streams_equal': True,
        'uart_hex': uart.hex(), 'full_F2_acceptance_complete': False, 'cpu_performance_benchmark': 'Pending'})
    print('DUAL_CORE_HELLO_PASS', result)


if __name__ == '__main__':
    main()
