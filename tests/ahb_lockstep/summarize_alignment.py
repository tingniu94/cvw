"""Independently replay Step 3C cycle CSV; reject duplicate/cross-ordinal pairs."""
import csv
import hashlib
import json
import re
import sys
from pathlib import Path

run = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parents[2]
rows = list(csv.DictReader((run / 'unit/alignment-cycles.csv').open()))
cases = list(csv.DictReader((run / 'unit/pairing-cases.csv').open()))
pending = [False, False]
sent = [False, False]
responded = [False, False]
accepts = [0, 0]
completions = [0, 0]
cancelled = [0, 0]
pair_count = 0
next_pair = 0
wait = a_wait = b_wait = backpressure = pairs = 0
for row in rows:
    value = {k: int(v) for k, v in row.items() if k not in ('time_ps', 'case')}
    if not value['resetn']:
        for side in range(2):
            cancelled[side] += int(pending[side])
        pending = [False, False]
        sent = [False, False]
        responded = [False, False]
        wait = a_wait = b_wait = backpressure = pairs = next_pair = 0
        assert not value['pair_valid'] and not value['pair_handshake']
        continue
    assert [value[k] for k in ['wait_cycles', 'a_wait', 'b_wait', 'backpressure', 'pairs', 'pair_seq']] == [wait, a_wait, b_wait, backpressure, pairs, next_pair]
    assert bool(value['pair_valid']) == bool(value['a_req_valid'] and value['b_req_valid'])
    if value['a_req_valid'] != value['b_req_valid']:
        wait += 1
        a_wait += value['a_req_valid']
        b_wait += value['b_req_valid']
    backpressure += int(value['pair_valid'] and not value['pair_ready'])
    if value['pair_handshake']:
        assert all(pending) and not any(sent)
        sent = [True, True]
        pair_count += 1
        pairs += 1
        next_pair = (next_pair + 1) % 8  # unit SEQ_WIDTH=3
    for side, prefix in enumerate(('a', 'b')):
        if value[prefix + '_rsp_capture']:
            assert pending[side] and sent[side] and not responded[side]
            responded[side] = True
        if value[prefix + '_complete']:
            assert pending[side] and sent[side] and responded[side]
            completions[side] += 1
            pending[side] = sent[side] = responded[side] = False
        if value[prefix + '_ready'] and value[prefix + '_trans_valid']:
            assert not pending[side]
            accepts[side] += 1
            pending[side] = True
assert not any(pending)
assert all(accepts[s] == completions[s] + cancelled[s] for s in range(2))
for row in cases:
    assert int(row['expected_peer_wait']) == int(row['measured_peer_wait']), row
assert len(cases) == 15
assert pair_count == 18
assert 'ALIGNMENT_TEST_PASS' in (run / 'alignment-simulation.log').read_text()
for name in ('alignment-build', 'alignment-simulation', 'lint-32', 'step3b-regression', 'verification'):
    # verification-result is written by the caller after this summarizer exits.
    if name != 'verification':
        assert json.loads((run / (name + '-result.json')).read_text())['returncode'] == 0
    assert not re.search(r'%Warning|%Error|%Fatal|warning:|error:', (run / (name + '.log')).read_text())
regression = json.loads((run / 'step3b-regression/summary.json').read_text())
assert regression['status'] == 'PASS' and regression['final_build_warnings'] == 0
for filename, digest in json.loads((run / 'source-sha256.json').read_text()).items():
    assert hashlib.sha256((root / filename).read_bytes()).hexdigest() == digest
summary = {'status': 'PASS', 'cycles': len(rows), 'paired_requests_all_epochs': pair_count,
           'accepted_a_b': accepts, 'completed_a_b': completions,
           'reset_cancelled_a_b': cancelled, 'counter_epoch_final': {
               'peer_wait': wait, 'a_wait': a_wait, 'b_wait': b_wait,
               'consumer_backpressure': backpressure, 'paired_requests': pairs},
           'pairing_cases': cases, 'step3b_regression': 'PASS', 'lint_32': 'PASS',
           'build_warnings': 0, 'source_snapshot_unchanged': True}
with (run / 'summary.json').open('x') as output:
    json.dump(summary, output, indent=2)
    output.write('\n')
print(json.dumps(summary, indent=2))
