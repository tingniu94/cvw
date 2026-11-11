"""Recompute masks from full-width saved snapshots; replay handshake accounting."""
import csv
import hashlib
import json
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
run = Path(sys.argv[1]).resolve()


def rows(path):
    with path.open() as source:
        return list(csv.DictReader(source))


def decode(value, aw, dw, sw, qw):
    sizes = [('seq', qw), ('addr', aw), ('write', 1), ('size', 3), ('burst', 3),
             ('prot', 4), ('trans', 2), ('lock', 1), ('wdata', dw), ('wstrb', sw)]
    value = int(value, 16)
    result = {}
    for name, width in reversed(sizes):
        result[name] = value & ((1 << width) - 1)
        value >>= width
    assert value == 0
    return result


def reason(a, b, ordinal):
    pre = ((a['seq'] != b['seq'] or a['seq'] != ordinal) << 9)
    pre |= ((not a['trans'] & 2 or not b['trans'] & 2) << 10)
    if pre:
        return pre
    mask = sum((a[k] != b[k]) << i for i, k in
               enumerate(['addr', 'write', 'size', 'burst', 'prot', 'trans', 'lock']))
    if a['write'] and b['write']:
        mask |= (a['wdata'] != b['wdata']) << 7
        mask |= (a['wstrb'] != b['wstrb']) << 8
    return mask


width_results = {}
for name, (aw, dw, sw, qw) in json.loads((run / 'width-matrix.json').read_text()).items():
    cases = rows(run / name / 'compare-cases.csv')
    faults = 0
    for case in cases:
        assert case['input_a'] == case['saved_a'] and case['input_b'] == case['saved_b']
        a = decode(case['saved_a'], aw, dw, sw, qw)
        b = decode(case['saved_b'], aw, dw, sw, qw)
        mask = reason(a, b, int(case['result_seq']))
        assert mask == int(case['actual_mask'], 16) == int(case['expected_mask'], 16), case
        faults += mask != 0
    for prefix, width in [('addr_bit_', aw), ('data_bit_', dw), ('strobe_bit_', sw),
                          ('local_seq_bit_', qw), ('pair_seq_bit_', qw), ('size_bit_', 3),
                          ('burst_bit_', 3), ('prot_bit_', 4)]:
        indices = {int(c['case'][len(prefix):]) for c in cases if c['case'].startswith(prefix)}
        assert indices == set(range(width)), (name, prefix, indices)
    accepted = dispatched = fault_observations = 0
    pending = False
    sticky_fault = False
    for event in rows(run / name / 'compare-events.csv'):
        v = {k: int(value, 16 if k == 'reason' else 10) for k, value in event.items()
             if k != 'case'}
        if not v['resetn']:
            assert not v['match_valid'] and not v['fault_valid'] and not v['pair_ready']
            pending = sticky_fault = False
            continue
        assert bool(v['match_valid'] or v['fault_valid']) == pending
        assert not (v['match_valid'] and v['fault_valid'])
        if sticky_fault:
            assert v['fault_valid'] and not v['pair_ready'] and not v['match_valid']
        if v['fault_valid'] and not sticky_fault:
            fault_observations += 1
            sticky_fault = True
        if v['match_valid'] and v['match_ready']:
            assert pending and not sticky_fault
            dispatched += 1
            pending = False
        if v['pair_valid'] and v['pair_ready']:
            assert not pending
            accepted += 1
            pending = True
    assert accepted == len(cases) + 1 and dispatched == len(cases) - faults
    assert fault_observations == faults
    assert 'COMPARE_TEST_PASS' in (run / (name + '-simulation.log')).read_text()
    width_results[name] = {'widths': [aw, dw, sw, qw], 'cases': len(cases),
                           'matches': len(cases) - faults, 'faults': faults,
                           'accepted': accepted, 'normal_dispatches': dispatched,
                           'reset_cancelled_pending_match': 1, 'all_bits_covered': True}

integration = rows(run / 'integration/integration-cases.csv')
assert len(integration) == 8
for case in integration:
    assert int(case['handoffs']) == 1
    assert int(case['dispatches']) == (case['result'] == 'MATCH')
accepted = [0, 0]
completed = [0, 0]
response = [0, 0]
cancelled = [0, 0]
pending = [False, False]
authorized = [False, False]
paired = [False, False]
handoffs = dispatches = 0
for event in rows(run / 'integration/integration-events.csv'):
    v = {k: int(value, 16 if k == 'reason' else 10) for k, value in event.items() if k != 'case'}
    if not v['resetn']:
        for s in range(2):
            cancelled[s] += pending[s]
        pending = [False, False]
        authorized = [False, False]
        paired = [False, False]
        continue
    if v['fault_valid']:
        assert not v['match_valid'] and not v['pair_ready']
        assert not any(v[k] for k in ['a_complete', 'b_complete', 'a_response', 'b_response'])
    if v['match_valid'] and v['match_ready']:
        assert all(paired) and not any(authorized) and not v['fault_valid']
        dispatches += 1
        authorized = [True, True]
    if v['pair_valid'] and v['pair_ready']:
        assert all(pending) and not any(paired)
        paired = [True, True]
        handoffs += 1
    for s, prefix in enumerate(['a', 'b']):
        if v[prefix + '_response']:
            assert authorized[s]
            response[s] += 1
        if v[prefix + '_complete']:
            assert pending[s] and authorized[s]
            completed[s] += 1
            pending[s] = paired[s] = authorized[s] = False
        if v[prefix + '_accept']:
            assert not pending[s]
            accepted[s] += 1
            pending[s] = True
assert (handoffs, dispatches, accepted, completed, cancelled, response) == (8, 7, [8, 8], [7, 7], [1, 1], [7, 7])
assert not any(pending)
assert 'COMPARE_INGRESS_TEST_PASS' in (run / 'integration-simulation.log').read_text()
regression = json.loads((run / 'step3c-regression/summary.json').read_text())
assert regression['status'] == 'PASS' and regression['step3b_regression'] == 'PASS'
for path in run.glob('*-result.json'):
    assert json.loads(path.read_text())['returncode'] == 0
for path in run.rglob('*.log'):
    assert not re.search(r'%Warning|%Error|%Fatal|warning:|error:', path.read_text()), path
for name, digest in json.loads((run / 'source-sha256.json').read_text()).items():
    assert hashlib.sha256((root / name).read_bytes()).hexdigest() == digest
summary = {'status': 'PASS', 'width_sweeps': width_results,
           'integration': {'cases': integration, 'handoffs': handoffs,
                           'normal_dispatches': dispatches, 'accepted_a_b': accepted,
                           'completed_a_b': completed, 'reset_cancelled_a_b': cancelled,
                           'mismatch_dispatches': 0, 'mismatch_fake_responses': 0},
           'step3c_regression': 'PASS', 'step3b_regression': 'PASS',
           'build_warnings': 0, 'source_snapshot_unchanged': True}
with (run / 'summary.json').open('x') as output:
    json.dump(summary, output, indent=2)
    output.write('\n')
print(json.dumps(summary, indent=2))
