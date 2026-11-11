"""Independent lifecycle replay and edge-index unit latency; no CPU ROI changes."""
import csv
import hashlib
import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
run = Path(sys.argv[1]).resolve()


def dump(path, value):
    with path.open('x') as output:
        json.dump(value, output, indent=2)
        output.write('\n')


def aggregate(values):
    return {'samples': len(values), 'sum': sum(values), 'min': min(values) if values else None,
            'max': max(values) if values else None, 'mean': sum(values) / len(values) if values else None}


widths = json.loads((run / 'width-matrix.json').read_text())
results = {}
for name, (aw, dw, sw) in widths.items():
    with (run / name / 'guard-events.csv').open() as f:
        rows = list(csv.DictReader(f))
    pending = [None, None]
    active = None
    first_available = None
    records = []
    cancelled_tokens = []
    counts = Counter()
    per_case_wait = {}
    for row in rows:
        hex_keys = ['compare_reason', 'gate_reason', 'down_addr', 'down_wdata', 'down_strb']
        v = {k: int(x, 16 if k in hex_keys else 2 if k == 'down_trans' else 10)
             for k, x in row.items() if k != 'case'}
        c = v['cycle']
        if not v['resetn']:
            for side, token in enumerate(pending):
                if token:
                    cancelled_tokens.append({'side': side, 'accepted_cycle': token['accepted'],
                                             'case': token['case'], 'reset_cycle': c})
                    counts[f'{side}_cancelled'] += 1
            if active is not None:
                active['reset_cycle'] = c
                active['cancelled'] = True
            pending = [None, None]
            active = None
            first_available = None
            continue
        assert v['a_complete'] == v['b_complete'] and v['a_rsp_capture'] == v['b_rsp_capture']
        waits = per_case_wait.setdefault(row['case'], Counter())
        if v['a_req'] != v['b_req']:
            counts['peer_wait'] += 1
            waits['peer_wait'] += 1
        for label, condition in [
            ('consumer_backpressure', v['match_valid'] and not v['match_ready']),
            ('address_backpressure', v['address_phase'] and not v['down_ready']),
            ('data_wait', v['data_phase'] and not v['down_ready']),
            ('response_backpressure', v['response_pending'] and not v['a_rsp_capture'])]:
            if condition:
                counts[label] += 1
                waits[label] += 1
        if v['pair_valid'] and first_available is None:
            first_available = c
        if v['pair_valid'] and v['pair_ready']:
            assert all(pending) and active is None
            active = {'case': pending[0]['case'], 'a_accepted': pending[0]['accepted'],
                      'b_accepted': pending[1]['accepted'], 'available': first_available,
                      'paired': c, 'cancelled': False, 'data_waits': 0}
            records.append(active)
            for token in pending:
                token['pair'] = active
            counts['pairs'] += 1
            first_available = None
        if v['authorized']:
            assert active is not None and 'authorized' not in active and not v['fault']
            active['authorized'] = c
            counts['authorized'] += 1
        if v['policy_reject']:
            assert active is not None and 'authorized' not in active
            active['policy_rejected'] = c
            counts['policy_rejected'] += 1
        if v['fault'] and v['compare_reason']:
            assert active is not None and 'authorized' not in active
            active.setdefault('compare_fault', v['compare_reason'])
            assert not v['down_accept'] and not v['a_complete'] and not v['a_rsp_capture']
        if v['down_accept']:
            assert active is not None and 'authorized' in active and 'down_accepted' not in active
            assert not v['fault'] and v['down_trans'] == 2 and v['down_burst'] == 0
            active.update(down_accepted=c, address=hex(v['down_addr']), write=bool(v['down_write']), seq=v['owner_seq'])
            counts['down_accepted'] += 1
        if v['data_phase'] and not v['down_ready']:
            assert active is not None and 'down_accepted' in active
            active['data_waits'] += 1
        if v['down_complete']:
            assert active is not None and 'down_accepted' in active and 'down_completed' not in active
            active.update(down_completed=c, error=bool(v['down_resp']))
            assert c - active['down_accepted'] == 1 + active['data_waits']
            counts['down_completed'] += 1
            if active['error']:
                counts['errors'] += 1
            else:
                counts['write_effects' if active['write'] else 'read_effects'] += 1
        if v['a_rsp_capture']:
            assert active is not None and 'down_completed' in active and 'rsp_captured' not in active
            active['rsp_captured'] = c
            counts['response_forks'] += 1
        for side, prefix in enumerate(['a', 'b']):
            if v[prefix + '_complete']:
                assert pending[side] is not None and 'pair' in pending[side]
                record = pending[side]['pair']
                assert 'rsp_captured' in record and bool(v['a_resp']) == record['error']
                record[prefix + '_completed'] = c
                counts[f'{side}_completed'] += 1
                pending[side] = None
        if v['a_complete']:
            assert active is not None and active['a_completed'] == active['b_completed']
            active = None
        # Old data completion precedes acceptance of a new address on this edge.
        for side, prefix in enumerate(['a', 'b']):
            if v[prefix + '_accept']:
                assert pending[side] is None
                counts[f'{side}_accepted'] += 1
                pending[side] = {'accepted': c, 'case': row['case']}
    assert pending == [None, None] and active is None
    for side in range(2):
        assert counts[f'{side}_accepted'] == counts[f'{side}_completed'] + counts[f'{side}_cancelled']
    complete = [r for r in records if 'a_completed' in r and 'b_completed' in r]
    assert counts['errors'] == 2
    rejects = [r for r in records if 'compare_fault' in r or 'policy_rejected' in r]
    assert len(rejects) == 8
    assert all('down_accepted' not in r and 'a_completed' not in r for r in rejects)
    metric_pairs = {'pair_available_to_authorized': ('available', 'authorized'),
                    'pair_handoff_to_authorized': ('paired', 'authorized'),
                    'authorized_to_down_accept': ('authorized', 'down_accepted'),
                    'down_accept_to_complete': ('down_accepted', 'down_completed'),
                    'down_complete_to_a_complete': ('down_completed', 'a_completed'),
                    'down_complete_to_b_complete': ('down_completed', 'b_completed'),
                    'a_accept_to_complete': ('a_accepted', 'a_completed'),
                    'b_accept_to_complete': ('b_accepted', 'b_completed')}
    latencies = {k: aggregate([r[end] - r[start] for r in complete])
                 for k, (start, end) in metric_pairs.items()}
    case_latencies = [{**{k: r[k] for k in ['case', 'error', 'write', 'address']},
                       **{k: r[end] - r[start] for k, (start, end) in metric_pairs.items()}}
                      for r in complete]
    for r in complete:
        expected_fork_delay = 3 if r['error'] else 2
        assert r['a_completed'] - r['down_completed'] == expected_fork_delay
    assert all('byte_lane_' + str(i) in [r['case'] for r in complete] for i in range(sw))
    log = (run / (name + '-simulation.log')).read_text()
    marker = next(line for line in log.splitlines() if line.startswith('GUARD_TEST_PASS'))
    observed = {k: int(value) for k, value in re.findall(r'(\w+)=(\d+)', marker)}
    for key, counter in [('pairs', 'pairs'), ('auth', 'authorized'), ('down_accept', 'down_accepted'),
                         ('down_complete', 'down_completed'), ('A_complete', '0_completed'),
                         ('B_complete', '1_completed'), ('A_cancel', '0_cancelled'),
                         ('B_cancel', '1_cancelled'), ('read_effects', 'read_effects'),
                         ('write_effects', 'write_effects'), ('errors', 'errors')]:
        assert observed[key] == counts[counter], (name, key, observed[key], counts[counter])
    dump(run / name / 'transactions.json', records)
    dump(run / name / 'cancelled-upstream.json', cancelled_tokens)
    dump(run / name / 'latency.json', {'unit': 'clock cycles', 'aggregate_completed_only': latencies,
                                     'per_completed_transaction': case_latencies,
                                     'waits_all_epochs': dict(counts),
                                     'waits_by_case': {k: dict(v) for k, v in per_case_wait.items()}})
    results[name] = {'widths': [aw, dw, sw], 'status': 'PASS', 'counts': dict(counts),
                     'completed_pairs': len(complete), 'rejected_pairs': len(rejects),
                     'latency_completed_only': latencies,
                     'downstream_completed_but_upstream_reset': sum(
                         'down_completed' in r and 'a_completed' not in r for r in records)}
assert 'OUTPUT_FORK_TEST_PASS a_responses=1 b_responses=1 one_side_backpressure=3' in (run / 'fork-simulation.log').read_text()
assert json.loads((run / 'step3d-regression/summary.json').read_text())['status'] == 'PASS'
for path in run.rglob('*.log'):
    assert not re.search(r'%Warning|%Error|%Fatal|warning:|error:', path.read_text()), path
for path in run.glob('*-result.json'):
    assert json.loads(path.read_text())['returncode'] == 0
for n, digest in json.loads((run / 'source-sha256.json').read_text()).items():
    assert hashlib.sha256((ROOT / n).read_bytes()).hexdigest() == digest
summary = {'status': 'PASS', 'scope': 'SINGLE/NONSEQ only; burst/SEQ/lock rejected',
           'widths': results, 'atomic_fork_backpressure': {'status': 'PASS', 'cycles': 3},
           'step3b_regression': 'PASS', 'step3c_regression': 'PASS', 'step3d_regression': 'PASS',
           'build_warnings': 0, 'source_snapshot_unchanged': True,
           'latency_is_cpu_cycle_overhead': False}
dump(run / 'summary.json', summary)
print(json.dumps(summary, indent=2))
