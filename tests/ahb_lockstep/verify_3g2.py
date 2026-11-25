"""Independently replay the real dual-core event ledger by ordered owner."""
import argparse
import csv
import json
from pathlib import Path


def rows(path):
    with path.open() as stream:
        return list(csv.DictReader(stream))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    parser.add_argument('single_uart', type=Path)
    args = parser.parse_args()
    run = args.run
    output = run / 'verification'
    output.mkdir(exist_ok=False)
    frames = rows(run / 'dual/dual-events.csv')
    last_reset = max(i for i, row in enumerate(frames) if row['reset'] == '1')
    by_cycle = {}
    for frame in frames[last_reset + 1:]:
        by_cycle.setdefault(int(frame['cycle']), frame)
    owners = []
    counts = dict.fromkeys(['a_accept', 'b_accept', 'pair', 'match', 'authorized', 'down_accept', 'down_complete', 'a_complete', 'b_complete'], 0)
    current = {'a': None, 'b': None}
    write_capture = {}
    pending = None
    overlap = 0
    for event in rows(run / 'dual/bus-ledger.csv'):
        cycle = int(event['cycle'])
        frame = by_cycle[cycle]
        for side, owner in list(write_capture.items()):
            owners[owner][side + '_wdata'] = frame[side + '_wdata']
            owners[owner][side + '_strb'] = frame[side + '_strb']
            del write_capture[side]
        for stage in ['a_complete', 'b_complete']:
            if event[stage] == '1':
                side = stage[0]
                owner = current[side]
                assert owner == counts[stage] and owner is not None
                entry = owners[owner]
                assert entry['down_complete'] < cycle
                assert frame[side + '_resp'] == entry['resp'] == '0'
                if entry['write'] == '0':
                    assert frame[side + '_rdata'] == entry['rdata']
                entry[stage] = cycle
                counts[stage] += 1
                current[side] = None
        for side in ['a', 'b']:
            stage = side + '_accept'
            if event[stage] == '1':
                owner = counts[stage]
                if owner == len(owners):
                    owners.append({'owner': owner})
                assert current[side] is None
                current[side] = owner
                entry = owners[owner]
                entry[stage] = cycle
                for field in ['addr', 'trans', 'burst', 'write']:
                    entry[side + '_' + field] = frame[side + '_' + field]
                write_capture[side] = owner
                counts[stage] += 1
        for stage in ['pair', 'match', 'authorized']:
            if event[stage] == '1':
                owner = counts[stage]
                entry = owners[owner]
                assert current['a'] == current['b'] == owner
                for field in ['addr', 'trans', 'burst', 'write']:
                    assert entry['a_' + field] == entry['b_' + field]
                if entry['a_write'] == '1':
                    assert entry['a_wdata'] == entry['b_wdata']
                    assert entry['a_strb'] == entry['b_strb']
                previous = {'pair': 'a_accept', 'match': 'pair', 'authorized': 'match'}[stage]
                assert entry[previous] <= cycle
                entry[stage] = cycle
                counts[stage] += 1
        if event['down_complete'] == '1':
            owner = int(event['owner'])
            assert owner == pending == counts['down_complete']
            entry = owners[owner]
            assert entry['down_accept'] < cycle
            entry.update(down_complete=cycle, rdata=event['rdata'], resp=event['resp'])
            if entry['write'] == '1':
                assert event['wdata'] == entry['a_wdata']
                assert event['strb'] == entry['a_strb']
            counts['down_complete'] += 1
            pending = None
        if event['down_accept'] == '1':
            owner = int(event['owner'])
            assert pending is None and owner == counts['down_accept']
            entry = owners[owner]
            assert entry['authorized'] <= cycle
            for field in ['addr', 'trans', 'burst', 'write']:
                assert event[field] == entry['a_' + field]
            entry.update(down_accept=cycle, addr=event['addr'], write=event['write'], size=event['size'])
            counts['down_accept'] += 1
            pending = owner
        overlap += int(event['down_accept'] == event['down_complete'] == '1')
    result = json.loads((run / 'dual/dual-result.json').read_text())
    assert pending is None and len(set(counts.values())) == 1
    assert counts['down_complete'] == result['completed']
    assert all(entry['a_complete'] == entry['b_complete'] for entry in owners)
    uart = rows(run / 'dual/uart-ledger.csv')
    assert len({row['owner'] for row in uart}) == len(uart) == result['uart_writes']
    for row in uart:
        entry = owners[int(row['owner'])]
        assert entry['write'] == '1' and entry['down_complete'] == int(row['cycle'])
        assert int(entry['a_wdata'], 16) & 255 == int(row['data'], 16)
    chars = bytes(int(row['data'], 16) for row in uart if row['character_write'] == '1')
    assert chars == (run / 'dual/logs/uart.out').read_bytes() == args.single_uart.read_bytes()
    (output / 'owner-ledger.json').write_text(json.dumps(owners, indent=2) + '\n')
    fields = sorted({key for entry in owners for key in entry})
    with (output / 'owner-ledger.csv').open('w') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(owners)
    summary = {'status': 'PASS', 'ordered_owner_counts': counts, 'uart_register_writes': len(uart),
               'uart_characters': len(chars), 'single_dual_uart_equal': True, 'downstream_overlap': overlap,
               'full_F2_acceptance_complete': False,
               'scope': 'CSV replay of saved observable fields; all payload controls also checked by RTL comparator'}
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary))


if __name__ == '__main__':
    main()
