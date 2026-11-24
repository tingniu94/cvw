"""F3a: full ingress mismatch and separately labelled module ownership tests."""
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
files = sources + ['tests/ahb_lockstep/' + name for name in ['f3a_mismatch_tb.sv', 'f3a_output_tb.sv', 'run_f3a.py']]
snapshot = run / 'source-snapshot'
snapshot.mkdir()
for name in files:
    (snapshot / Path(name).name).write_bytes((ROOT / name).read_bytes())
dump(run / 'source-sha256.json', {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in files})
dump(run / 'environment.json', {key: subprocess.check_output(argv, cwd=ROOT, text=True).strip() for key, argv in {
    'verilator': ['verilator', '--version'], 'head': ['git', 'rev-parse', 'HEAD'], 'branch': ['git', 'branch', '--show-current'],
    'status': ['git', 'status', '--short']}.items()})
results = {}
for name, aw, dw in [('rv64', 56, 64), ('rv32', 34, 32), ('explicit32', 32, 32), ('module', 56, 64)]:
    top = 'f3a_output_tb' if name == 'module' else 'f3a_mismatch_tb'
    command = ['verilator', '--binary', '--timing', '--trace-fst', '--assert', '--timescale', '1ps/1ps', '--top-module', top, '--Mdir', str(run / ('work-' + name))]
    if name != 'module':
        command += [f'-GAW={aw}', f'-GDW={dw}']
    command += [str(ROOT / source) for source in sources + ['tests/ahb_lockstep/' + top + '.sv']]
    lint_command = command.copy()
    lint_command[lint_command.index('--binary')] = '--lint-only'
    lint_command.remove('--trace-fst')
    execute(run, name + '-lint', lint_command, ROOT)
    assert '%Warning' not in (run / (name + '-lint.log')).read_text()
    execute(run, name + '-build', command, ROOT)
    assert '%Warning' not in (run / (name + '-build.log')).read_text()
    runtime = run / name
    runtime.mkdir()
    execute(run, name + '-simulation', [str(run / ('work-' + name) / ('V' + top))], runtime)
    log = (run / (name + '-simulation.log')).read_text()
    marker = 'F3A_MODULE_PASS' if name == 'module' else 'F3A_GUARD_PASS'
    assert marker in log
    results[name] = {'status': 'PASS', 'scope': 'MODULE_LEVEL_ONLY' if name == 'module' else 'FULL_GUARD',
                     'result': next(line for line in log.splitlines() if line.startswith(marker))}
    if name != 'module':
        with (runtime / 'fault-ledger.csv').open() as stream:
            faults = list(csv.DictReader(stream))
        assert len(faults) == 336
        with (runtime / 'guard-events.csv').open() as stream:
            events = list(csv.DictReader(stream))
        first_fault = {}
        prior_event = None
        for row in events:
            if row['fault'] == '1' and row['case'].startswith('mismatch_epoch_'):
                fault_epoch = int(row['case'].split('_')[2])
                first_fault.setdefault(fault_epoch, (row, prior_event))
            prior_event = row
        def unpack(value, address_width, data_width):
            packed = int(value, 16)
            decoded = {}
            for field, width in [('strb', data_width // 8), ('data', data_width), ('lock', 1), ('trans', 2), ('prot', 4), ('burst', 3), ('size', 3), ('write', 1), ('addr', address_width)]:
                decoded[field] = hex(packed & ((1 << width) - 1))
                packed >>= width
            assert packed == 0
            return decoded
        for fault in faults:
            edge, cause = first_fault[int(fault['epoch'])]
            assert cause['pair_valid'] == cause['pair_ready'] == '1'
            fault['comparator_fault_update_edge_ps'] = int(cause['time_ps'])
            fault['transaction_sequence'] = int(fault['beat_index_0based'])
            fault['first_sampled_fault_edge_ps'] = int(edge['time_ps'])
            fault['first_sampled_fault_cycle'] = int(edge['cycle'])
            for field in ['original_b', 'original_a', 'corrupted_b']:
                fault[field + '_decoded'] = unpack(fault[field], aw, dw)
            for counter in ['authorized', 'accepted', 'completed', 'writes']:
                assert fault[counter + '_before'] == fault[counter + '_after']
            assert int(fault['validator_fault'], 16) == 1 and int(fault['gate_fault'], 16) & 1
        dump(runtime / 'fault-ledger.json', faults)
        owners = owner_ledger(events)
        dump(runtime / 'owner-ledger.json', owners)
        memory_snapshots = {}
        with (runtime / 'memory.csv').open() as stream:
            for row in csv.DictReader(stream):
                memory_snapshots.setdefault((row['epoch'], row['snapshot']), bytearray()).append(int(row['value'], 16))
        for fault in faults:
            epoch_owners = [owner for owner in owners if owner['epoch'] == int(fault['epoch'])]
            completed_prefix = [owner for owner in epoch_owners if owner['status'] == '完成']
            assert len(completed_prefix) == int(fault['beat_index_0based'])
            blocked = next(owner for owner in epoch_owners if owner['ordinal'] == int(fault['beat_index_0based']))
            assert 'pair' in blocked and 'authorization' not in blocked and 'address_accept' not in blocked
            before = memory_snapshots[(fault['epoch'], 'before_fault')]
            after = memory_snapshots[(fault['epoch'], 'after_fault')]
            assert len(before) == len(after) == 256 and before == after
            fault['completed_prefix_writes'] = sum(owner['write'] == '1' for owner in completed_prefix)
            fault['fault_and_later_write_effects'] = 0
            fault['memory_bytes_changed_after_fault'] = 0
            fault['memory_before_sha256'] = hashlib.sha256(before).hexdigest()
            fault['memory_after_sha256'] = hashlib.sha256(after).hexdigest()
        dump(runtime / 'fault-evidence.json', faults)
        with (runtime / 'owner-ledger.csv').open('x', newline='') as stream:
            writer = csv.DictWriter(stream, fieldnames=sorted({key for owner in owners for key in owner}))
            writer.writeheader()
            writer.writerows(owners)
        results[name]['mismatch_cases'] = len(faults)
        results[name]['owners'] = len(owners)
        results[name]['cancelled_owners'] = sum(owner['status'] != '完成' for owner in owners)
        results[name]['unauthorized_write_effects'] = 0
        results[name]['post_fault_authorizations'] = 0
        results[name]['events'] = len(events)
assert all((ROOT / name).read_bytes() == (snapshot / Path(name).name).read_bytes() for name in files), 'Source changed during run'
dump(run / 'summary.json', {'status': 'PASS', 'tests': results, 'build_warnings': 0,
                           'full_F2_acceptance_complete': False,
                           'full_guard_new_mismatch_during_old_data_pending': 'NOT_REACHABLE_IN_CURRENT_ARCHITECTURE',
                           'F3b_HRESP_ERROR': 'Pending', 'real_dual_core': 'Pending'})
print('F3A_PASS', run / 'summary.json')
