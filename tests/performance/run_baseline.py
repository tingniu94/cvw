#!/usr/bin/env python3
"""Isolated archive baseline. No checkout, Git writes, or application RTL edits."""
import argparse
import hashlib
import io
import json
import os
import shlex
import shutil
import subprocess
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COMMITS = {'original': 'be4b5af64', 'step2': '8ff5bf247'}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, value):
    with Path(path).open('x') as f:
        json.dump(value, f, indent=2, sort_keys=True)
        f.write('\n')


def git(*args, cwd=ROOT):
    return subprocess.check_output(['git', *args], cwd=cwd)


def extract(data, dest):
    # Only archives generated from the specified local Git objects.
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        archive.extractall(dest, filter='data')


def prepare(run):
    snapshot = run / 'instrumentation'
    snapshot.mkdir()
    tb = (ROOT / 'testbench/testbench.sv').read_text()
    begin = tb.index('  // PERFORMANCE_BASELINE_BEGIN')
    end = tb.index('\n', tb.index('  // PERFORMANCE_BASELINE_END')) + 1
    # Include the insertion's trailing blank line, leaving original TB exact.
    if tb[end:end+1] == '\n':
        end += 1
    block = tb[begin:end]
    (snapshot / 'integration.sv.txt').write_text(block)
    shutil.copy2(ROOT / 'testbench/common/performance_monitor.sv', snapshot)
    shutil.copy2(ROOT / 'tests/performance/performance_monitor_tb.sv', snapshot)
    hashes = {p.name: sha(p) for p in sorted(snapshot.iterdir())}
    digest = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
    save(snapshot / 'manifest.json', {'sha256': digest, 'files': hashes})
    inputs = run / 'inputs'
    inputs.mkdir()
    for suffix in ('', '.memfile', '.objdump', '.objdump.addr', '.objdump.lab'):
        shutil.copy2(ROOT / ('examples/C/hello/hello' + suffix), inputs)
    input_hashes = {p.name: sha(p) for p in sorted(inputs.iterdir())}
    save(run / 'inputs-manifest.json', {'source': str(ROOT / 'examples/C/hello'),
                                      'files': input_hashes})
    preflight = {'branch': git('branch', '--show-current').decode().strip(),
                 'head': git('rev-parse', 'HEAD').decode().strip(),
                 'git_status': git('status', '--short').decode(),
                 'instrumentation_hash': digest, 'versions': {},
                 'tool': subprocess.check_output(['verilator', '--version']).decode().strip(),
                 'clock_period_ps': 10, 'timescale': '1ps/1ps',
                 'roi': 'reset_release_to_tb_complete_v1', 'configuration': 'rv64gc'}
    original_tb = None
    configs = None
    for name, revision in COMMITS.items():
        dest = run / name
        dest.mkdir()
        src = dest / 'source'
        src.mkdir()
        full = git('rev-parse', revision).decode().strip()
        archive = git('archive', '--format=tar', full)
        (dest / 'source.tar').write_bytes(archive)
        extract(archive, src)
        # Materialize exactly the recorded Ethernet submodule; no network/update.
        ethernet_commit = git('ls-tree', full, 'addins/verilog-ethernet').decode().split()[2]
        subarchive = git('archive', '--format=tar', ethernet_commit, cwd=ROOT/'addins/verilog-ethernet')
        (dest / 'ethernet.tar').write_bytes(subarchive)
        extract(subarchive, src / 'addins/verilog-ethernet')
        tbpath = src / 'testbench/testbench.sv'
        raw = tbpath.read_text()
        if original_tb is None:
            original_tb = raw
        if raw != original_tb:
            raise RuntimeError('Baseline testbench differs: adapter review required')
        if tb[:begin] + tb[end:] != raw:
            raise RuntimeError('Working testbench has changes beyond snapshot block')
        marker = '  // generate clock to sequence tests\n'
        if raw.count(marker) != 1:
            raise RuntimeError('Integration marker not unique')
        tbpath.write_text(raw.replace(marker, block + marker))
        shutil.copy2(snapshot / 'performance_monitor.sv', src / 'testbench/common')
        assert sha(src/'testbench/common/performance_monitor.sv') == hashes['performance_monitor.sv']
        for path, needles in {
            'src/privileged/csr.sv': ['InstrValidNotFlushedM = InstrValidM & ~StallW & ~FlushW'],
            'src/wally/wallypipelinedcore.sv': ['StallF, StallD, StallE, StallM, StallW'],
            'src/privileged/csrc.sv': ['HPMCOUNTER_REGW', 'WriteHPMCOUNTERM', 'CounterInc'],
        }.items():
            text = (src/path).read_text()
            assert all(x in text for x in needles), path
        config = {str(p.relative_to(src)): sha(p) for d in ('config/rv64gc', 'config/shared')
                  for p in sorted((src/d).rglob('*')) if p.is_file()}
        if configs is not None and configs != config:
            raise RuntimeError('Configuration mismatch')
        configs = config
        (dest / 'runtime/logs').mkdir(parents=True)
        sources = {str(p.relative_to(src)): sha(p) for d in ('src', 'config', 'testbench', 'sim/verilator', 'addins/verilog-ethernet')
                   for p in sorted((src/d).rglob('*')) if p.is_file()}
        manifest = {'source_commit': full, 'source_archive_sha256': sha(dest/'source.tar'),
                    'ethernet_commit': ethernet_commit, 'ethernet_archive_sha256': sha(dest/'ethernet.tar'),
                    'instrumentation_hash': digest, 'input_files': input_hashes,
                    'configuration': config, 'instrumented_source_hashes': sources,
                    'hierarchy_adapter': None, 'monitor_bus': 'SoC downstream HADDR/HREADY/dut.HRESP'}
        save(dest / 'manifest.json', manifest)
        preflight['versions'][name] = {'commit': full, 'testbench_before_instrumentation_sha256': hashlib.sha256(raw.encode()).hexdigest()}
    save(run / 'preflight.json', preflight)
    shutil.copy2(__file__, run/'run_baseline.py')
    print('PREPARE_PASS', digest)


def execute(run, name, action):
    dest = run / name
    src = dest / 'source'
    env = dict(os.environ, WALLY=str(src), RISCV='/opt/riscv')
    if action == 'build':
        command = ['make', '-C', str(src/'sim/verilator'), 'WALLYCONF=rv64gc',
                   'TESTBENCH=testbench', 'PARAM_ARGS=MAKE_VCD=1',
                   'VERILATOR_FLAGS=--assert --no-trace-top --stats --timing --timescale 1ps/1ps',
                   'WORKDIR='+str(dest/'work-hello')]
        cwd = run
    else:
        command = [str(dest/'work-hello/Vtestbench'), '+TEST=hello_hello',
                   '+ElfFile='+str(run/'inputs/hello'), '+AHB_MONITOR_LIMIT=0',
                   '+UART_LOG=1', '+UART_LOG_FILE=logs/uart.out',
                   '+PERFORMANCE_JSON='+str(dest/'runtime/performance.json')]
        cwd = dest/'runtime'
    expected_inputs = json.loads((run/'inputs-manifest.json').read_text())['files']
    for file, digest in expected_inputs.items():
        assert sha(run/'inputs'/file) == digest, 'Input hash changed before run'
    record = {'argv': command, 'shell_display': shlex.join(command), 'cwd': str(cwd),
              'env': {'WALLY': env['WALLY'], 'RISCV': env['RISCV']}}
    save(dest/(action+'-command.json'), record)
    with (dest/(action+'.log')).open('x') as log:
        result = subprocess.run(command, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=900)
    save(dest/(action+'-result.json'), {'returncode': result.returncode})
    for file, digest in expected_inputs.items():
        assert sha(run/'inputs'/file) == digest, 'Input hash changed during run'
    if result.returncode:
        raise RuntimeError(f'{name} {action} failed: {result.returncode}; inspect log')
    print(name, action, 'PASS')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('run', type=Path)
    parser.add_argument('action', choices=['prepare', 'build', 'simulate'])
    parser.add_argument('--version', choices=COMMITS)
    args = parser.parse_args()
    run = args.run.resolve()
    if args.action == 'prepare':
        prepare(run)
    else:
        if not args.version:
            parser.error('--version required')
        execute(run, args.version, args.action)
