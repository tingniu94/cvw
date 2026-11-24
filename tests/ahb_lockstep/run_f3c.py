"""Run user-configurable F3c injection through the real Guard RTL."""
import argparse
import configparser
import csv
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = ROOT / 'artifacts/ahb-lockstep-step3f'
SOURCES = ['src/ebu/ahb_lockstep_' + name + '.sv' for name in ['ingress', 'pair', 'dual_ingress', 'compare', 'burst_context', 'output', 'guard']]
TB = 'tests/ahb_lockstep/f3c_fault_tb.sv'
WIDTHS = {'rv64': (56, 64), 'rv32': (34, 32), 'explicit32': (32, 32)}
SIGNALS = {'HWRITE': 1, 'HSIZE': 3, 'HBURST': 3, 'HPROT': 4, 'HTRANS': 2, 'HWSTRB': 0, 'HMASTLOCK': 1}
KEYS = {
    'run': 'CONFIGURATION WORKLOAD SAVE_WAVEFORM BASE_DELAY_A BASE_DELAY_B DOWNSTREAM_WAIT_CYCLES WATCHDOG_CYCLES',
    'fault': 'FAULT_ENABLE FAULT_TARGET FAULT_LOCATION FAULT_TYPE',
    'data': 'DATA_MODE DATA_VALUE FAULT_BIT XOR_MASK',
    'address': 'ADDRESS_MODE ADDRESS_BIT ADDRESS_VALUE ADDRESS_XOR_MASK',
    'control': 'CONTROL_SIGNAL CONTROL_VALUE', 'delay': 'DELAY_CYCLES',
    'trigger': 'TRIGGER_MODE INJECT_AT_TRANSACTION INJECT_AT_CYCLE INJECT_AT_BEAT',
}


def dump(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, ensure_ascii=False)
        stream.write('\n')


def unique_directory(parent, prefix):
    parent.mkdir(parents=True, exist_ok=True)
    for index in range(1, 1000000):
        path = parent / f'{prefix}-{index:03d}'
        try:
            path.mkdir()
            return path
        except FileExistsError:
            continue
    raise ValueError('結果目錄編號已用盡')


def parse_config(path):
    text = path.read_text(encoding='utf-8')
    headers = re.findall(r'^\s*\[([^]\n]+)\]', text, re.MULTILINE)
    unknown = set(headers) - set(KEYS)
    if unknown:
        raise ValueError('未知 INI Section: ' + ', '.join(sorted(unknown)))
    parser = configparser.ConfigParser(interpolation=None, strict=True)
    parser.optionxform = str
    try:
        parser.read_string(text)
    except configparser.DuplicateOptionError as error:
        raise ValueError(f'重複設定 Key: [{error.section}] {error.option}') from error
    except configparser.DuplicateSectionError as error:
        raise ValueError(f'重複 INI Section: {error.section}') from error
    if set(parser.sections()) != set(KEYS):
        raise ValueError('INI 必須包含全部指定 Section')
    values = {}
    for section, keys in KEYS.items():
        if set(parser[section]) != set(keys.split()):
            raise ValueError(f'[{section}] 的參數缺漏或未知: ' + ', '.join(sorted(set(parser[section]) ^ set(keys.split()))))
        values[section] = dict(parser[section])

    def read(section, key, kind, choices=(), nullable=False):
        raw = values[section][key]
        if raw == 'none' and nullable:
            value = None
        elif kind == 'enum' and raw in choices:
            value = raw
        elif kind == 'bool' and raw in ('true', 'false'):
            value = raw == 'true'
        elif kind == 'int' and re.fullmatch(r'[0-9]+', raw):
            value = int(raw, 10)
        elif kind == 'hex' and re.fullmatch(r'0x[0-9a-fA-F]+', raw):
            value = int(raw, 16)
        else:
            hint = ' / '.join(choices) if kind == 'enum' else {'bool': 'true / false', 'int': '十進位 Integer', 'hex': '0x 開頭的 Hex'}[kind]
            raise ValueError(f'[{section}] {key} 格式錯誤: {raw}; 支援格式: {hint}')
        values[section][key] = value
        return value

    def bound(value, low, high, label):
        if value is None or not low <= value <= high:
            raise ValueError(f'{label} 必須介於 {low} 到 {high}')

    configuration = read('run', 'CONFIGURATION', 'enum', WIDTHS)
    aw, dw = WIDTHS[configuration]
    workload = read('run', 'WORKLOAD', 'enum', ('write_incr8', 'read_incr8', 'mixed'))
    wave = read('run', 'SAVE_WAVEFORM', 'bool')
    for key in ('BASE_DELAY_A', 'BASE_DELAY_B', 'DOWNSTREAM_WAIT_CYCLES', 'WATCHDOG_CYCLES'):
        number = read('run', key, 'int')
        bound(number, 32 if key == 'WATCHDOG_CYCLES' else 0, 100000 if key == 'WATCHDOG_CYCLES' else 32, key)
    enabled = read('fault', 'FAULT_ENABLE', 'bool')
    target = read('fault', 'FAULT_TARGET', 'enum', ('A', 'B'))
    read('fault', 'FAULT_LOCATION', 'enum', ('Ingress',))
    fault_type = read('fault', 'FAULT_TYPE', 'enum', ('Data', 'Address', 'Control', 'Delay'))
    for section, mode_key, bit_key, value_key, mask_key in [('data', 'DATA_MODE', 'FAULT_BIT', 'DATA_VALUE', 'XOR_MASK'), ('address', 'ADDRESS_MODE', 'ADDRESS_BIT', 'ADDRESS_VALUE', 'ADDRESS_XOR_MASK')]:
        read(section, mode_key, 'enum', ('bit_flip', 'replace', 'xor_mask'), True)
        read(section, bit_key, 'int', nullable=True)
        read(section, value_key, 'hex', nullable=True)
        read(section, mask_key, 'hex', nullable=True)
    signal = read('control', 'CONTROL_SIGNAL', 'enum', SIGNALS, True)
    control_value = read('control', 'CONTROL_VALUE', 'hex', nullable=True)
    delay = read('delay', 'DELAY_CYCLES', 'int', nullable=True)
    trigger = read('trigger', 'TRIGGER_MODE', 'enum', ('transaction', 'cycle'))
    transaction = read('trigger', 'INJECT_AT_TRANSACTION', 'int', nullable=True)
    cycle = read('trigger', 'INJECT_AT_CYCLE', 'int', nullable=True)
    beat = read('trigger', 'INJECT_AT_BEAT', 'int', nullable=True)
    if beat is not None:
        bound(beat, 1, 8, 'INJECT_AT_BEAT')
    if trigger == 'transaction':
        bound(transaction, 1, 16 if workload == 'mixed' else 8, 'INJECT_AT_TRANSACTION')
        if cycle is not None:
            raise ValueError('transaction 模式的 INJECT_AT_CYCLE 必須為 none')
        if beat is not None and beat != (transaction - 1) % 8 + 1:
            raise ValueError('Transaction 與 Beat 設定衝突')
    else:
        bound(cycle, 0, values['run']['WATCHDOG_CYCLES'] - 1, 'INJECT_AT_CYCLE')
        if transaction is not None:
            raise ValueError('cycle 模式的 INJECT_AT_TRANSACTION 必須為 none')
    write_trigger = workload != 'read_incr8' and not (workload == 'mixed' and trigger == 'transaction' and transaction > 8)
    mode = 'replace'
    bit = 0
    value = 0
    if enabled and fault_type in ('Data', 'Address'):
        section, prefix, width = ('data', 'DATA', dw) if fault_type == 'Data' else ('address', 'ADDRESS', aw)
        mode = values[section][prefix + '_MODE']
        if mode is None:
            raise ValueError('啟用的 Fault Mode 不可為 none')
        if mode == 'bit_flip':
            bit = values[section]['FAULT_BIT' if section == 'data' else 'ADDRESS_BIT']
            bound(bit, 0, width - 1, prefix + '_BIT')
        else:
            key = prefix + '_VALUE' if mode == 'replace' else ('XOR_MASK' if section == 'data' else 'ADDRESS_XOR_MASK')
            value = values[section][key]
            bound(value, 0, (1 << width) - 1, key)
    if enabled and fault_type == 'Control':
        if signal is None:
            raise ValueError('CONTROL_SIGNAL 不可為 none')
        bound(control_value, 0, (1 << (SIGNALS[signal] or dw // 8)) - 1, 'CONTROL_VALUE')
        value = control_value
        if signal == 'HTRANS' and value == 0:
            raise ValueError('HTRANS=IDLE 會提前結束固定 INCR8; F3c 不支援安全注入此模式, 請使用 NONSEQ/SEQ 或 Burst 內 BUSY')
        if signal == 'HTRANS' and value == 1 and trigger == 'transaction' and (transaction - 1) % 8 == 0:
            raise ValueError('BUSY 不能建立 Burst 的第一筆 Request')
    if enabled and fault_type == 'Delay':
        bound(delay, 0, 128, 'DELAY_CYCLES')
    if enabled and (fault_type == 'Data' or (fault_type == 'Control' and signal == 'HWSTRB')) and not write_trigger:
        raise ValueError('Read Request 不能使用 Write HWDATA/HWSTRB Fault')
    args = {'ENABLE': int(enabled), 'TARGET': int(target == 'B'), 'TYPE': ('Data', 'Address', 'Control', 'Delay').index(fault_type) + 1,
            'OP': ('bit_flip', 'replace', 'xor_mask').index(mode) + 1, 'SIGNAL': list(SIGNALS).index(signal) if signal else -1,
            'BIT': bit, 'VALUE': f'{value:x}', 'DELAY': delay if enabled and fault_type == 'Delay' else 0,
            'TRIGGER_MODE': int(trigger == 'cycle'), 'TRANSACTION': transaction if transaction is not None else -1,
            'CYCLE': cycle if cycle is not None else -1, 'BEAT': beat or 0,
            'WORKLOAD': ('write_incr8', 'read_incr8', 'mixed').index(workload), 'WAVE': int(wave),
            'BASE_A': values['run']['BASE_DELAY_A'], 'BASE_B': values['run']['BASE_DELAY_B'],
            'WATCHDOG': values['run']['WATCHDOG_CYCLES'], 'DATA_WAIT': values['run']['DOWNSTREAM_WAIT_CYCLES']}
    return {'settings': values, 'addr_width': aw, 'data_width': dw, 'plusargs': args}


def execute(folder, name, command, cwd):
    dump(folder / (name + '-command.json'), {'argv': command, 'cwd': str(cwd)})
    with (folder / (name + '.log')).open('x') as output:
        result = subprocess.run(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT, timeout=300)
    if result.returncode:
        if 'watchdog timeout' in (folder / (name + '.log')).read_text():
            raise RuntimeError('Simulation Watchdog Timeout, 不能視為成功偵測')
        raise RuntimeError(f'{name} 失敗, 請查看 {folder / (name + ".log")}')


def binary_for(parsed):
    version = subprocess.check_output(['verilator', '--version'], text=True).strip()
    hashes = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in SOURCES + [TB]}
    key = hashlib.sha256(json.dumps([hashes, parsed['addr_width'], parsed['data_width'], version, 'timing/assert/fst/1ps-v1'], sort_keys=True).encode()).hexdigest()
    for candidate in sorted(ARTIFACTS.glob('f3c-build-' + key[:20] + '-*')):
        manifest = candidate / 'build.json'
        if manifest.exists():
            data = json.loads(manifest.read_text())
            binary = candidate / 'work/Vf3c_fault_tb'
            if data['key'] == key and data['binary_sha256'] == hashlib.sha256(binary.read_bytes()).hexdigest():
                return binary, candidate, hashes, version
    build = unique_directory(ARTIFACTS, 'f3c-build-' + key[:20])
    dump(build / 'source-sha256.json', hashes)
    snapshot = build / 'source-snapshot'
    snapshot.mkdir()
    for name in hashes:
        (snapshot / Path(name).name).write_bytes((ROOT / name).read_bytes())
    command = ['verilator', '--binary', '--timing', '--trace-fst', '--assert', '--timescale', '1ps/1ps', '--top-module', 'f3c_fault_tb', '--Mdir', str(build / 'work'),
               f'-GAW={parsed["addr_width"]}', f'-GDW={parsed["data_width"]}'] + [str(ROOT / name) for name in hashes]
    lint = command.copy(); lint[lint.index('--binary')] = '--lint-only'; lint.remove('--trace-fst')
    execute(build, 'lint', lint, ROOT)
    execute(build, 'build', command, ROOT)
    for step in ('lint', 'build'):
        if '%Warning' in (build / (step + '.log')).read_text():
            raise RuntimeError('Build/Lint 出現 Warning, 不能使用此 Build')
    binary = build / 'work/Vf3c_fault_tb'
    dump(build / 'build.json', {'key': key, 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'verilator': version})
    return binary, build, hashes, version


def decode_payload(value, aw, dw):
    packed = int(value, 16)
    result = {}
    for name, width in [('HWSTRB', dw // 8), ('HWDATA', dw), ('HMASTLOCK', 1), ('HTRANS', 2), ('HPROT', 4), ('HBURST', 3), ('HSIZE', 3), ('HWRITE', 1), ('HADDR', aw)]:
        result[name] = hex(packed & ((1 << width) - 1))
        packed >>= width
    assert packed == 0, 'Invalid payload width'
    return result


def collect(run, parsed):
    with (run / 'tb-result.csv').open() as stream:
        row = next(csv.DictReader(stream))
    result = int(row['result'])
    labels = ['NO_FAULT_PASS', 'MISMATCH_DETECTED', 'DELAY_VERIFIED', 'DELAY_ZERO_VERIFIED', 'NO_EFFECT', 'NOT_INJECTED', 'NOT_INJECTED_VALID_REQUEST', 'TRIGGER_CONFLICT_OR_READ_LANES']
    success = result in (0, 1, 2, 3)
    with (run / 'injection.csv').open() as stream:
        injections = list(csv.DictReader(stream))
    for injection in injections:
        injection['target_core'] = parsed['settings']['fault']['FAULT_TARGET']
        for key in ('original_payload', 'injected_payload'):
            injection[key + '_decoded'] = decode_payload(injection[key], parsed['addr_width'], parsed['data_width'])
    memory = {}
    with (run / 'memory.csv').open() as stream:
        for sample in csv.DictReader(stream):
            memory.setdefault(sample['snapshot'], bytearray()).append(int(sample['value'], 16))
    if result == 1:
        assert row['applied'] == row['detected'] == row['fail_closed'] == '1'
        assert int(row['compare_reason'], 16) == 1 << int(row['expected_reason'])
        assert row['validator_fault'] == '1' and int(row['validator_reason'], 16) == 128
        assert memory['before_injection'] == memory['final']
        assert int(row['auth']) == int(row['transaction']) - 1
    if result in (0, 2, 3, 4, 5):
        expected = 16 if parsed['settings']['run']['WORKLOAD'] == 'mixed' else 8
        assert all(int(row[key]) == expected for key in ('auth', 'accepted', 'completed', 'a_completed', 'b_completed'))
        assert row['detected'] == '0'
    if result in (2, 3):
        assert int(row['actual_delay']) == parsed['plusargs']['DELAY']
    with (run / 'guard-events.csv').open() as stream:
        events = list(csv.DictReader(stream))
    owners = {}
    expected_memory = memory['initial'].copy()
    pending_address = None
    for event in events:
        if event['resetn'] != '1' or not event['case'].startswith('transaction_'):
            continue
        ordinal = int(event['case'].split('_')[1])
        owner = owners.setdefault(ordinal, {'reset_epoch': 1, 'transaction': ordinal, 'beat': (ordinal - 1) % 8 + 1})
        for key in ('a_accept', 'b_accept', 'authorized', 'down_accept', 'down_complete', 'a_complete', 'b_complete'):
            if event[key] == '1':
                assert key not in owner, 'Duplicate owner event'
                owner[key] = int(event['time_ps'])
        if event['pair_valid'] == event['pair_ready'] == '1':
            assert 'pair' not in owner, 'Duplicate pair'
            owner['pair'] = int(event['time_ps'])
        if event['authorized'] == '1':
            assert event['match_valid'] == event['match_ready'] == '1', 'Missing registered MATCH'
            owner['registered_match'] = int(event['time_ps'])
        if event['down_accept'] == '1':
            assert pending_address is None and 'authorized' in owner, 'Unowned downstream address'
            assert int(event['owner_seq']) == ordinal - 1, 'Wrong downstream owner'
            pending_address = (int(event['down_addr'], 16) & 255, event['down_write'] == '1', ordinal)
        if event['down_complete'] == '1':
            assert pending_address is not None and pending_address[2] == ordinal, 'Wrong data owner'
            address, write, _ = pending_address
            if write:
                value = int(event['down_wdata'], 16)
                mask = int(event['down_strb'], 16)
                for lane in range(parsed['data_width'] // 8):
                    if mask & (1 << lane):
                        expected_memory[address + lane] = (value >> (8 * lane)) & 255
            pending_address = None
    assert expected_memory == memory['final'], 'Unexpected memory side effect'
    assert sum(event['policy_reject'] == '1' for event in events) == 0, 'Unexpected validator policy rejection'
    dump(run / 'owner-ledger.json', list(owners.values()))
    with (run / 'owner-ledger.csv').open('x', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=sorted({key for owner in owners.values() for key in owner}))
        writer.writeheader(); writer.writerows(owners.values())
    dump(run / 'injection.json', injections)
    dump(run / 'memory-sha256.json', {name: hashlib.sha256(data).hexdigest() for name, data in memory.items()})
    summary = {'status': 'PASS' if success else ('NO_EFFECT' if result == 4 else 'NOT_INJECTED' if result in (5, 6) else 'INVALID_TRIGGER'),
               'result': labels[result], 'INJECTION_REQUESTED': row['requested'] == '1', 'INJECTION_APPLIED': row['applied'] == '1',
               'FAULT_DETECTED': row['detected'] == '1', 'FAIL_CLOSED_VERIFIED': row['fail_closed'] == '1',
               'reset_epoch': 1, 'tb': row, 'injection': injections,
               'detection_latency_cycles': int(row['first_fault_cycle']) - int(row['applied_cycle']) if result == 1 else None,
               'unauthorized_write_side_effects': 0, 'validator_policy_reject': False,
               'fault_origin': 'COMPARATOR_MISMATCH' if result == 1 else None, 'full_F2_acceptance_complete': False,
               'inflight_next_mismatch': 'NOT_REACHABLE_IN_CURRENT_ARCHITECTURE', 'real_dual_core': 'Pending'}
    if not success:
        summary['error'] = {4: '注入值未改變有效 Payload: NO_EFFECT', 5: '指定 Cycle 沒有安全且符合條件的 Request', 6: 'BUSY 不會建立有效 Request, 未形成 Comparator Mismatch', 7: 'Cycle Trigger 與 Beat 衝突或命中不適用的 Request'}[result]
    dump(run / 'summary.json', summary)
    return 0 if success else 4 if result == 4 else 3


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / 'tests/ahb_lockstep/fault_config.ini')
    parser.add_argument('--artifacts-root', type=Path, default=ARTIFACTS)
    args = parser.parse_args()
    run = unique_directory(args.artifacts_root.resolve(), 'f3c-run')
    code = 1
    try:
        dump(run / 'requested-source-sha256.json', {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in SOURCES + [TB, 'tests/ahb_lockstep/run_f3c.py']})
        if not args.config.is_file():
            raise ValueError('找不到設定檔: ' + str(args.config))
        (run / 'config-snapshot.ini').write_bytes(args.config.read_bytes())
        try:
            parsed = parse_config(args.config)
        except (ValueError, configparser.Error, UnicodeError) as error:
            raise ValueError('設定檔驗證失敗: ' + str(error)) from error
        dump(run / 'parsed-configuration.json', parsed)
        binary, build, hashes, version = binary_for(parsed)
        (run / 'runner-source.py').write_bytes(Path(__file__).read_bytes())
        dump(run / 'source-sha256.json', {**hashes, 'tests/ahb_lockstep/run_f3c.py': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()})
        dump(run / 'environment.json', {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
             'build_evidence': str(build), 'verilator': version, 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest()})
        with (run / 'git.diff').open('x') as stream:
            subprocess.run(['git', 'diff', '--', 'src/ebu', 'tests/ahb_lockstep', 'docs/meeting-progress-log.md'], cwd=ROOT, stdout=stream, check=True)
            for name in [TB, 'tests/ahb_lockstep/run_f3c.py', 'tests/ahb_lockstep/fault_config.ini']:
                tracked = subprocess.run(['git', 'ls-files', '--error-unmatch', '--', name], cwd=ROOT, capture_output=True).returncode == 0
                if not tracked:
                    diff = subprocess.run(['git', 'diff', '--no-index', '--', '/dev/null', name], cwd=ROOT, stdout=stream, check=False)
                    assert diff.returncode == 1
        execute(run, 'simulation', [str(binary)] + [f'+{key}={value}' for key, value in parsed['plusargs'].items()], run)
        assert all(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == digest for name, digest in hashes.items()), 'Source changed during simulation'
        code = collect(run, parsed)
    except ValueError as error:
        dump(run / 'summary.json', {'status': 'INVALID_CONFIGURATION', 'error': str(error), 'INJECTION_REQUESTED': False,
                                    'INJECTION_APPLIED': False, 'FAULT_DETECTED': False, 'FAIL_CLOSED_VERIFIED': False})
        (run / 'error.log').write_text('設定錯誤: ' + str(error) + '\n')
        print('設定錯誤: ' + str(error), file=sys.stderr); code = 2
    except (OSError, RuntimeError, subprocess.SubprocessError, AssertionError) as error:
        if not (run / 'summary.json').exists():
            dump(run / 'summary.json', {'status': 'FAIL', 'error': str(error) or 'Assertion 驗證失敗, 請查看原始 Ledger'})
        (run / 'error.log').write_text('執行失敗: ' + str(error) + '\n')
        print('執行失敗: ' + str(error), file=sys.stderr); code = 1
    dump(run / 'exit-code.json', {'exit_code': code})
    print('結果目錄: ' + str(run))
    if (run / 'summary.json').exists():
        print((run / 'summary.json').read_text())
    return code


if __name__ == '__main__':
    sys.exit(main())
