"""F3b:完整 Guard 的兩 Cycle ERROR、Owner、Burst 取消與共同 Reset。"""
import csv
import hashlib
import subprocess
import sys
from pathlib import Path

from run_alignment import dump, execute


def owner_ledger(events):
    """逐 Epoch / Ordinal 檢查 Pair 到 Completion 或共同 Reset 的所有權。"""
    epoch = 0
    previous_reset = False
    ordinals = [0, 0]
    current = [None, None]
    ledger = {}
    for row in events:
        reset = row['resetn'] == '1'
        if not reset:
            for owner in ledger.values():
                if owner['epoch'] == epoch and owner['status'] == 'pending':
                    owner['status'] = '共同 Reset 取消'
                    owner['reset_cycle'] = int(row['cycle'])
            previous_reset = False
            current = [None, None]
            continue
        if not previous_reset:
            epoch += 1
            ordinals = [0, 0]
        previous_reset = True
        cycle = int(row['cycle'])
        # Completion consumes the previous owner before a same-edge new address.
        for side, prefix in enumerate(['a', 'b']):
            if row[prefix + '_complete'] == '1':
                owner = ledger[current[side]]
                assert 'data_complete' in owner and prefix + '_complete' not in owner
                owner[prefix + '_complete'] = cycle
                if 'a_complete' in owner and 'b_complete' in owner:
                    owner['status'] = '完成'
        for side, prefix in enumerate(['a', 'b']):
            if row[prefix + '_accept'] == '1':
                identity = (epoch, ordinals[side])
                ordinals[side] += 1
                current[side] = identity
                owner = ledger.setdefault(identity, {'epoch': epoch, 'ordinal': identity[1], 'status': 'pending'})
                assert prefix + '_accept' not in owner
                owner[prefix + '_accept'] = cycle
        for event, column in [('pair', 'pair_valid'), ('authorization', 'authorized'), ('address_accept', 'down_accept'), ('data_complete', 'down_complete')]:
            active = row[column] == '1' and (event != 'pair' or row['pair_ready'] == '1')
            if not active:
                continue
            assert current[0] is not None and current[0] == current[1]
            owner = ledger[current[0]]
            assert event not in owner
            prerequisite = {'pair': 'b_accept', 'authorization': 'pair', 'address_accept': 'authorization', 'data_complete': 'address_accept'}[event]
            assert prerequisite in owner and owner[prerequisite] < cycle
            owner[event] = cycle
            if event == 'address_accept':
                owner['address'] = row['down_addr']
                owner['write'] = row['down_write']
                assert int(row['owner_seq']) == owner['ordinal'] % 256
            if event == 'data_complete':
                owner['data'] = row['down_wdata'] if owner['write'] == '1' else row['down_rdata']
                owner['strobe'] = row['down_strb']
        if row['fault'] == '1' and current[0] == current[1] and current[0] is not None:
            ledger[current[0]].setdefault('fault_sample_cycle', cycle)
    owners = list(ledger.values())
    assert all(owner['status'] != 'pending' for owner in owners)
    return owners

ROOT = Path(__file__).resolve().parents[2]
run = Path(sys.argv[1]).resolve()
run.mkdir(parents=True, exist_ok=False)
sources = ['src/ebu/ahb_lockstep_' + name + '.sv' for name in ['ingress', 'pair', 'dual_ingress', 'compare', 'burst_context', 'output', 'guard']]
files = sources + ['tests/ahb_lockstep/f3b_error_tb.sv', 'tests/ahb_lockstep/run_f3b.py']
protected = ['tests/riscof/config.ini', 'tests/ahb_lockstep/f3a_mismatch_tb.sv', 'tests/ahb_lockstep/f3a_output_tb.sv', 'tests/ahb_lockstep/run_f3a.py', 'docs/ahb-dual-core-step3f-f3a.md']
snapshot = run / 'source-snapshot'
snapshot.mkdir()
for name in files:
    (snapshot / Path(name).name).write_bytes((ROOT / name).read_bytes())
dump(run / 'source-sha256.json', {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in files})
dump(run / 'protected-sha256.json', {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in protected})
dump(run / 'environment.json', {key: subprocess.check_output(argv, cwd=ROOT, text=True).strip() for key, argv in {
    'verilator': ['verilator', '--version'], 'head': ['git', 'rev-parse', 'HEAD'], 'branch': ['git', 'branch', '--show-current'],
    'status': ['git', 'status', '--short']}.items()})
results = {}
for name, aw, dw in [('rv64', 56, 64), ('rv32', 34, 32), ('explicit32', 32, 32)]:
    command = ['verilator', '--binary', '--timing', '--trace-fst', '--assert', '--timescale', '1ps/1ps', '--top-module', 'f3b_error_tb', '--Mdir', str(run / ('work-' + name)), f'-GAW={aw}', f'-GDW={dw}']
    command += [str(ROOT / source) for source in sources + ['tests/ahb_lockstep/f3b_error_tb.sv']]
    lint_command = command.copy()
    lint_command[lint_command.index('--binary')] = '--lint-only'
    lint_command.remove('--trace-fst')
    execute(run, name + '-lint', lint_command, ROOT)
    execute(run, name + '-build', command, ROOT)
    for step in ['lint', 'build']:
        assert '%Warning' not in (run / (name + '-' + step + '.log')).read_text()
    runtime = run / name
    runtime.mkdir()
    execute(run, name + '-simulation', [str(run / ('work-' + name) / 'Vf3b_error_tb')], runtime)
    log = (run / (name + '-simulation.log')).read_text()
    assert 'F3B_PASS' in log
    with (runtime / 'error-ledger.csv').open() as stream:
        errors = list(csv.DictReader(stream))
    with (runtime / 'guard-events.csv').open() as stream:
        events = list(csv.DictReader(stream))
    owners = owner_ledger(events)
    assert len(errors) == 144
    dump(runtime / 'owner-ledger.json', owners)
    with (runtime / 'owner-ledger.csv').open('x', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=sorted({key for owner in owners for key in owner}))
        writer.writeheader()
        writer.writerows(owners)
    with (runtime / 'error-cycle-trace.csv').open() as stream:
        trace = list(csv.DictReader(stream))
    memory = {}
    with (runtime / 'memory.csv').open() as stream:
        for row in csv.DictReader(stream):
            memory.setdefault((row['epoch'], row['snapshot']), bytearray()).append(int(row['value'], 16))
    for error in errors:
        rows = [row for row in trace if row['epoch'] == error['epoch'] and row['case'].startswith('error_epoch_')]
        first = next(row for row in rows if row['down_resp'] == '1' and row['down_ready'] == '0')
        second = next(row for row in rows if row['down_resp'] == row['down_ready'] == '1')
        upstream_first = next(row for row in rows if row['a_resp'] == '1' and row['a_ready'] == '0')
        upstream_second = next(row for row in rows if row['a_resp'] == row['a_ready'] == '1')
        assert int(second['time_ps']) - int(first['time_ps']) == 10
        assert int(upstream_second['time_ps']) - int(upstream_first['time_ps']) == 10
        assert int(upstream_first['time_ps']) > int(second['time_ps'])
        assert first['complete'] == '0' and second['complete'] == '1'
        assert first['a_resp'] == '0' and first['b_resp'] == '0'
        assert upstream_first['a_resp'] == upstream_first['b_resp'] == '1'
        assert upstream_second['a_ready'] == upstream_second['b_ready'] == '1'
        assert any(row['halted'] == '1' and int(row['gate_fault'], 16) == 2 for row in rows)
        error.update({'downstream_error_first_edge_ps': int(first['time_ps']), 'downstream_error_second_edge_ps': int(second['time_ps']),
                      'upstream_error_first_edge_ps': int(upstream_first['time_ps']), 'upstream_error_second_edge_ps': int(upstream_second['time_ps'])})
        owner = next(owner for owner in owners if owner['epoch'] == int(error['epoch']) and owner['ordinal'] == int(error['beat_index_0based']))
        assert owner['status'] == '完成' and owner['data_complete'] * 10 + 5 == int(second['time_ps'])
        assert owner['a_complete'] == owner['b_complete']
        before = memory[(error['epoch'], 'before_error')]
        after = memory[(error['epoch'], 'after_error')]
        assert len(before) == len(after) == 256
        if error['direction'] != '2':
            assert before == after
        error.update({'memory_before_sha256': hashlib.sha256(before).hexdigest(), 'memory_after_sha256': hashlib.sha256(after).hexdigest(),
                      'memory_changed_bytes': sum(a != b for a, b in zip(before, after)), 'unauthorized_write_effects': 0})
    dump(runtime / 'error-ledger.json', errors)
    results[name] = {'status': 'PASS', 'scope': 'FULL_GUARD', 'error_cases': 144, 'reset_cases': 6,
                     'error_write_committing_cases': 48, 'unauthorized_write_effects': 0,
                     'result': next(line for line in log.splitlines() if line.startswith('F3B_PASS'))}
assert all((ROOT / name).read_bytes() == (snapshot / Path(name).name).read_bytes() for name in files), 'Source changed during run'
dump(run / 'summary.json', {'status': 'PASS', 'tests': results, 'build_warnings': 0, 'full_F2_acceptance_complete': False,
                           'new_mismatch_while_old_data_pending': 'NOT_REACHABLE_IN_CURRENT_ARCHITECTURE',
                           'cpu_bus_error_trap': 'Pending', 'real_dual_core': 'Pending'})
print('F3B_PASS', run / 'summary.json')
