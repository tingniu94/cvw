"""Measure identical frozen Hello inputs with real single and dual CPU RTL."""
import argparse
import hashlib
import subprocess
from pathlib import Path

from run_3g1 import ROOT, dump, execute, rtl_sources


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    run = args.output.resolve()
    run.mkdir(parents=True, exist_ok=False)
    rtl = rtl_sources(subprocess.check_output(['git', 'ls-files', 'src'], cwd=ROOT, text=True).splitlines())
    bench = ['testbench/testbench.sv'] + sorted(str(p.relative_to(ROOT)) for p in (ROOT / 'testbench/common').glob('*.sv'))
    ethernet = sorted(str(p.relative_to(ROOT)) for p in (ROOT / 'addins/verilog-ethernet').rglob('*.sv'))
    sources = rtl + bench + ethernet
    assert 'src/ebu/ahb_guard.sv' not in sources
    support = ['testbench/common/dualcore_monitor.svh', 'testbench/common/cpu_performance.svh',
               'tests/ahb_lockstep/run_3g3.py', 'sim/verilator/Makefile', 'sim/verilator/wrapper.c']
    support += sorted(str(p.relative_to(ROOT)) for directory in ['config/rv64gc', 'config/shared'] for p in (ROOT / directory).glob('*.vh'))
    snapshot = run / 'source-snapshot'
    for name in sources + support:
        target = snapshot / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((ROOT / name).read_bytes())
    hashes = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sources + support}
    dump(run / 'source-sha256.json', hashes)
    dump(run / 'source-manifest.json', {'rtl_and_bench': sources, 'support': support})
    dump(run / 'environment.json', {key: subprocess.check_output(command, cwd=ROOT, text=True).strip() for key, command in {
        'head': ['git', 'rev-parse', 'HEAD'], 'branch': ['git', 'branch', '--show-current'],
        'status': ['git', 'status', '--short'], 'verilator': ['verilator', '--version']}.items()})
    dump(run / 'protected-sha256.json', {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in
        ['tests/riscof/config.ini', 'tests/ahb_lockstep/fault_config.ini']})
    inputs = run / 'inputs'
    inputs.mkdir()
    for suffix in ['', '.memfile', '.objdump', '.objdump.addr', '.objdump.lab']:
        (inputs / ('hello' + suffix)).write_bytes((ROOT / ('examples/C/hello/hello' + suffix)).read_bytes())
    dump(run / 'inputs-sha256.json', {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs.iterdir()})
    text = subprocess.check_output(['riscv64-unknown-elf-nm', '-n', str(inputs / 'hello')], text=True)
    (run / 'elf-symbols.txt').write_text(text)
    symbols = [int(line.split()[0], 16) for line in text.splitlines() if len(line.split()) == 3 and line.split()[2] == 'tohost']
    assert len(symbols) == 1 and symbols[0]
    paths = [str(ROOT / name) for name in sources]
    for mode in ['single', 'dual']:
        defines = '+define+CVW_CPU_PERFORMANCE' + ('+CVW_DUAL_CORE' if mode == 'dual' else '')
        lint = ['verilator', '--lint-only', '--timing', '--assert', '--relative-includes', '--timescale', '1ps/1ps', '--top-module', 'testbench',
                '-I' + str(ROOT / 'config/rv64gc'), '-I' + str(ROOT / 'config/shared'), defines, '-GMAKE_VCD=1'] + paths
        execute(run, mode + '-lint', lint)
        command = ['make', '-C', str(ROOT / 'sim/verilator'), 'WALLYCONF=rv64gc', 'TESTBENCH=testbench',
                   'SOURCES=' + ' '.join(paths), 'DEFINE_ARGS=' + defines, 'PARAM_ARGS=MAKE_VCD=1', 'WORKDIR=' + str(run / ('work-' + mode)),
                   'VERILATOR_FLAGS=--assert --timing --trace-fst --no-trace-top --stats --timescale 1ps/1ps']
        execute(run, mode + '-build', command)
        runtime = run / mode
        (runtime / 'logs').mkdir(parents=True)
        execute(run, mode + '-simulation', [str(run / ('work-' + mode) / 'Vtestbench'), '+TEST=hello_hello', '+ElfFile=' + str(inputs / 'hello'),
            '+DUAL_TOHOST=' + format(symbols[0], 'x'), '+PERFORMANCE_JSON=legacy-performance.json',
            '+AHB_MONITOR_LIMIT=0', '+UART_LOG=1', '+UART_LOG_FILE=logs/uart.out'], runtime)
        assert (runtime / 'logs/uart.out').read_bytes() == b'Hello Wally!\n\r0 1 2 3 4 5 6 7 8 9 \n\r'
    for name, digest in hashes.items():
        assert hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == digest, 'Source changed'
    print('SINGLE_HELLO_PASS DUAL_HELLO_PASS; run summarize_3g3.py for independent counter verification')


if __name__ == '__main__':
    main()
