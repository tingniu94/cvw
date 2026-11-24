"""Independently replay real Uncore side effects and pre-edge A/B ownership."""
import argparse
import csv
import hashlib
import json
import subprocess
from pathlib import Path


def dump(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2); stream.write('\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('run', type=Path); parser.add_argument('--output', type=Path)
    args = parser.parse_args(); run = args.run.resolve(); gate = run / 'gate'
    output = args.output.resolve() if args.output else run / 'verification'
    output.mkdir(parents=True, exist_ok=False)
    with (gate / 'guard-events.csv').open() as stream:
        events = {int(row['time_ps']): row for row in csv.DictReader(stream)}
    wanted = ['addr', 'wd', 'strb', 'wr', 'lock', 'size', 'burst', 'prot', 'trans', 'rd', 'resp', 'ready']
    wanted = [f'uncore_gate_tb.{name}[{side}]' for name in wanted for side in range(2)] + [
        'uncore_gate_tb.actual_uncore.ram.ram.memwriteD', 'uncore_gate_tb.actual_uncore.ram.ram.HADDRD',
        'uncore_gate_tb.actual_uncore.uartgen.uart.MEMWb', 'uncore_gate_tb.actual_uncore.uartgen.uart.Din',
        'uncore_gate_tb.actual_uncore.uartgen.uart.uartPC.DLAB'] + ['uncore_gate_tb.actual_uncore.' + name for name in ['PSEL', 'PENABLE', 'PWRITE', 'PADDR', 'PWDATA', 'PSTRB']]
    vcd = output / 'derived.vcd'
    with vcd.open('x') as waveform:
        subprocess.run(['fst2vcd', str(gate / 'uncore-gate.fst')], stdout=waveform, check=True)
    names = {}; scopes = []; values = {}; updates = {}; samples = {}; time = 0
    def flush():
        if time in events:
            samples[time] = {name: int(values[identifier], 2) for name, identifier in names.items()}
        values.update(updates)
    with vcd.open() as stream:
        for line in stream:
            line = line.strip(); parts = line.split()
            if line.startswith('$scope'):
                scopes.append(parts[2])
            elif line.startswith('$upscope'):
                scopes.pop()
            elif line.startswith('$var'):
                name = '.'.join(scopes + [parts[4]])
                if name in wanted:
                    names[name] = parts[3]
            elif line.startswith('#'):
                flush(); time = int(line[1:]); updates = {}
            elif line and line[0] in '01xz':
                updates[line[1:]] = line[0]
            elif line.startswith('b'):
                updates[parts[1]] = parts[0][1:]
        flush()
    assert set(names) == set(wanted), set(wanted) - set(names)
    owners = {}; ordinal = [0, 0]; current = [None, None]; capture = [None, None]
    epoch = 0; previous_reset = False; pending = None; ram = []; uart = []
    expected = bytearray(i ^ 0x5a for i in range(256))
    for time, row in events.items():
        if row['resetn'] == '0':
            assert pending is None, 'Unexpected reset cancellation in this gate'
            previous_reset = False; current = [None, None]; capture = [None, None]; continue
        if not previous_reset:
            epoch += 1; ordinal = [0, 0]
        previous_reset = True
        sample = samples[time]
        def value(name, sample=sample):
            return sample['uncore_gate_tb.' + name]
        for side, prefix in enumerate(['a', 'b']):
            if capture[side] is not None:
                payload = owners[capture[side]][prefix + '_payload']
                payload.update(data=value(f'wd[{side}]'), strobe=value(f'strb[{side}]'))
                capture[side] = None
            if row[prefix + '_complete'] == '1':
                owner = owners[current[side]]; assert 'data_complete' in owner and prefix + '_complete' not in owner
                owner[prefix + '_complete'] = time
                assert value(f'rd[{side}]') == owner['response_data'] and value(f'resp[{side}]') == 0
            if row[prefix + '_accept'] == '1':
                identity = f'{epoch}:{ordinal[side]}'; ordinal[side] += 1; current[side] = identity
                owner = owners.setdefault(identity, {'epoch': epoch, 'ordinal_0based': ordinal[side] - 1})
                payload = {field: value(f'{signal}[{side}]') for field, signal in [('address', 'addr'), ('write', 'wr'), ('size', 'size'), ('burst', 'burst'), ('prot', 'prot'), ('trans', 'trans'), ('lock', 'lock')]}
                owner[prefix + '_payload'] = payload; owner[prefix + '_accept'] = time
                if payload['write']:
                    capture[side] = identity
        for event, condition in [('pair', row['pair_valid'] == row['pair_ready'] == '1'), ('authorization', row['authorized'] == '1'), ('address_accept', row['down_accept'] == '1'), ('data_complete', row['down_complete'] == '1')]:
            if not condition:
                continue
            assert current[0] == current[1] and current[0] is not None
            owner = owners[current[0]]; assert event not in owner
            owner[event] = time
            if event == 'pair':
                assert owner['a_payload'] == owner['b_payload'], 'Wrong pairing'
            if event == 'authorization':
                assert 'pair' in owner and row['match_valid'] == row['match_ready'] == '1'
                owner['registered_match'] = time
            if event == 'address_accept':
                assert 'authorization' in owner and pending is None and int(row['owner_seq']) == owner['ordinal_0based']
                payload = owner['a_payload']; assert int(row['down_addr'], 16) == payload['address'] and int(row['down_trans'], 2) == payload['trans']
                pending = current[0]
            if event == 'data_complete':
                assert pending == current[0]
                payload = owner['a_payload']; owner['response_data'] = int(row['down_rdata'], 16)
                if payload['write']:
                    assert int(row['down_wdata'], 16) == payload['data'] and int(row['down_strb'], 16) == payload['strobe']
                pending = None
        if value('actual_uncore.ram.ram.memwriteD'):
            owner = owners[current[0]]; payload = owner['a_payload']
            assert row['down_complete'] == '1' and payload['write'] and payload['address'] >= 0x80000000
            assert value('actual_uncore.ram.ram.HADDRD') == payload['address'] and 'ram_effect' not in owner
            owner['ram_effect'] = time
            for lane in range(8):
                if payload['strobe'] & (1 << lane):
                    expected[(payload['address'] & 255 & ~7) + lane] = (payload['data'] >> (8 * lane)) & 255
            ram.append({'time_ps': time, 'epoch': epoch, 'owner': current[0], **payload})
        if not value('actual_uncore.uartgen.uart.MEMWb'):
            owner = owners[current[0]]; payload = owner['a_payload']
            assert row['down_complete'] == '1' and payload['address'] == 0x10000000 and payload['write'] and 'uart_effect' not in owner
            assert not value('actual_uncore.uartgen.uart.uartPC.DLAB')
            assert value('actual_uncore.PSEL') == 8 and value('actual_uncore.PENABLE') == value('actual_uncore.PWRITE') == 1
            assert value('actual_uncore.uartgen.uart.Din') == payload['data'] & 255
            assert value('actual_uncore.PADDR') == payload['address'] and value('actual_uncore.PWDATA') == payload['data'] and value('actual_uncore.PSTRB') == payload['strobe']
            owner['uart_effect'] = time
            uart.append({'time_ps': time, 'epoch': epoch, 'owner': current[0], **{name: value('actual_uncore.' + name) for name in ['PSEL', 'PENABLE', 'PWRITE', 'PADDR', 'PWDATA', 'PSTRB']}})
    with (gate / 'memory.csv').open() as stream:
        final = bytearray(int(row['value'], 16) for row in csv.DictReader(stream) if row['snapshot'] == 'final')
    assert final == expected and len(owners) == 61 and len(ram) == 33 and len(uart) == 1
    assert all(all(key in owner for key in ['a_accept', 'b_accept', 'pair', 'registered_match', 'authorization', 'address_accept', 'data_complete', 'a_complete', 'b_complete']) for owner in owners.values())
    assert all(owner['a_complete'] == owner['b_complete'] for owner in owners.values())
    dump(output / 'ab-downstream-ledger.json', owners)
    for name, rows in [('owner-ledger', [{'owner': key, **owner} for key, owner in owners.items()]), ('ram-side-effects', ram), ('uart-apb-ledger', uart)]:
        with (output / (name + '.csv')).open('x', newline='') as stream:
            writer = csv.DictWriter(stream, fieldnames=sorted({key for row in rows for key in row})); writer.writeheader(); writer.writerows(rows)
    dump(output / 'uncore-replay.json', {'status': 'PASS', 'epochs': epoch, 'owners': len(owners), 'ram_effects': len(ram), 'uart_effects': len(uart), 'unauthorized_write_effects': 0, 'memory_sha256': hashlib.sha256(final).hexdigest(), 'source': 'SYNTHETIC_AB_REAL_UNCORE'})
    dump(output / 'verifier-sha256.json', {'source': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'fst': hashlib.sha256((gate / 'uncore-gate.fst').read_bytes()).hexdigest()})
    print('UNCORE_REPLAY_PASS', len(owners))


if __name__ == '__main__':
    main()
