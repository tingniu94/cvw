"""Exercise manual INI scenarios through run_f3c.py, including expected failures."""
import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

from run_f3c import ROOT, WIDTHS, dump


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    run = args.output.resolve(); run.mkdir(parents=True, exist_ok=False)
    configs = run / 'configs'; configs.mkdir()
    cases_root = run / 'cases'; cases_root.mkdir()
    sources = [Path(__file__), ROOT / 'tests/ahb_lockstep/run_f3c.py', ROOT / 'tests/ahb_lockstep/fault_config.ini']
    snapshot = run / 'tool-source-snapshot'; snapshot.mkdir()
    for source in sources:
        (snapshot / source.name).write_bytes(source.read_bytes())
    dump(run / 'tool-source-sha256.json', {str(source.relative_to(ROOT)): hashlib.sha256(source.read_bytes()).hexdigest() for source in sources})
    template = (ROOT / 'tests/ahb_lockstep/fault_config.ini').read_text()
    scenarios = []

    def add(name, changes=None, expected='PASS', reason=None, transform=None):
        settings = {'CONFIGURATION': 'rv64', **(changes or {})}
        text = template
        for key, value in settings.items():
            text, count = re.subn(r'^' + key + r' = .*$', key + ' = ' + str(value), text, flags=re.MULTILINE)
            assert count == 1
        if transform:
            text = transform(text)
        scenarios.append((name, text, expected, reason))

    for configuration, (_, dw) in WIDTHS.items():
        for workload in ['write_incr8', 'read_incr8', 'mixed']:
            for da, db in [(0, 0), (3, 0), (0, 3)]:
                add(f'normal-{configuration}-{workload}-{da}-{db}', {'CONFIGURATION': configuration, 'WORKLOAD': workload, 'FAULT_ENABLE': 'false', 'BASE_DELAY_A': da, 'BASE_DELAY_B': db})
        for target in ['A', 'B']:
            for mode in ['bit_flip', 'replace', 'xor_mask']:
                for beat in [1, 5, 8]:
                    add(f'data-{configuration}-{target}-{mode}-{beat}', {'CONFIGURATION': configuration, 'FAULT_TARGET': target, 'DATA_MODE': mode, 'INJECT_AT_TRANSACTION': beat, 'INJECT_AT_BEAT': beat}, reason=7)
                    add(f'address-{configuration}-{target}-{mode}-{beat}', {'CONFIGURATION': configuration, 'FAULT_TARGET': target, 'FAULT_TYPE': 'Address', 'ADDRESS_MODE': mode, 'ADDRESS_BIT': 0, 'WORKLOAD': 'read_incr8' if mode == 'bit_flip' else 'write_incr8', 'INJECT_AT_TRANSACTION': beat, 'INJECT_AT_BEAT': beat}, reason=0)
            for signal, value, reason in [('HWRITE', '0x0', 1), ('HSIZE', '0x1', 2), ('HBURST', '0x0', 3), ('HPROT', '0x2', 4), ('HTRANS', '0x2', 5), ('HWSTRB', '0x0', 8), ('HMASTLOCK', '0x1', 6)]:
                add(f'control-{configuration}-{target}-{signal}', {'CONFIGURATION': configuration, 'FAULT_TARGET': target, 'FAULT_TYPE': 'Control', 'CONTROL_SIGNAL': signal, 'CONTROL_VALUE': value}, reason=reason)
            for delay in [0, 1, 3, 8]:
                add(f'delay-{configuration}-{target}-{delay}', {'CONFIGURATION': configuration, 'FAULT_TARGET': target, 'FAULT_TYPE': 'Delay', 'DELAY_CYCLES': delay, 'WORKLOAD': 'read_incr8' if delay == 8 else 'write_incr8'}, expected='DELAY_ZERO_VERIFIED' if delay == 0 else 'DELAY_VERIFIED')
        original = (0xfedcba9876543210 ^ (4 * 0x12345)) & ((1 << dw) - 1)
        add(f'no-effect-{configuration}', {'CONFIGURATION': configuration, 'DATA_VALUE': hex(original)}, expected='NO_EFFECT')
        add(f'zero-mask-{configuration}', {'CONFIGURATION': configuration, 'DATA_MODE': 'xor_mask', 'XOR_MASK': '0x0'}, expected='NO_EFFECT')
        add(f'cycle-hit-{configuration}', {'CONFIGURATION': configuration, 'TRIGGER_MODE': 'cycle', 'INJECT_AT_TRANSACTION': 'none', 'INJECT_AT_CYCLE': 0, 'INJECT_AT_BEAT': 1}, reason=7)
        add(f'cycle-miss-{configuration}', {'CONFIGURATION': configuration, 'TRIGGER_MODE': 'cycle', 'INJECT_AT_TRANSACTION': 'none', 'INJECT_AT_CYCLE': 1, 'INJECT_AT_BEAT': 'none'}, expected='NOT_INJECTED')
        add(f'busy-{configuration}', {'CONFIGURATION': configuration, 'FAULT_TYPE': 'Control', 'CONTROL_SIGNAL': 'HTRANS', 'CONTROL_VALUE': '0x1'}, expected='NOT_INJECTED')
        add(f'data-bit-range-{configuration}', {'CONFIGURATION': configuration, 'DATA_MODE': 'bit_flip', 'FAULT_BIT': dw}, expected='INVALID_CONFIGURATION')
        add(f'data-value-range-{configuration}', {'CONFIGURATION': configuration, 'DATA_VALUE': hex(1 << dw)}, expected='INVALID_CONFIGURATION')
    add('ignored-replace-width', {'DATA_MODE': 'bit_flip', 'DATA_VALUE': hex(1 << 80), 'XOR_MASK': 'none'}, reason=7)
    add('ignored-fields-disabled', {'FAULT_ENABLE': 'false', 'DATA_MODE': 'none', 'DATA_VALUE': 'none', 'FAULT_BIT': 'none', 'XOR_MASK': 'none', 'DELAY_CYCLES': 'none'})
    add('wave-disabled', {'FAULT_ENABLE': 'false', 'SAVE_WAVEFORM': 'false'})
    add('cycle-skew-hit', {'TRIGGER_MODE': 'cycle', 'INJECT_AT_TRANSACTION': 'none', 'INJECT_AT_CYCLE': 3, 'INJECT_AT_BEAT': 1, 'BASE_DELAY_B': 3}, reason=7)
    add('cycle-beat-conflict', {'TRIGGER_MODE': 'cycle', 'INJECT_AT_TRANSACTION': 'none', 'INJECT_AT_CYCLE': 0, 'INJECT_AT_BEAT': 5}, expected='INVALID_TRIGGER')
    add('watchdog', {'FAULT_ENABLE': 'false', 'WATCHDOG_CYCLES': 32}, expected='FAIL')
    invalid = [
        ('hex', {'DATA_VALUE': '0xGG'}), ('transaction', {'INJECT_AT_TRANSACTION': 9, 'INJECT_AT_BEAT': 'none'}),
        ('location', {'FAULT_LOCATION': 'CoreRTL'}), ('signal', {'FAULT_TYPE': 'Control', 'CONTROL_SIGNAL': 'BAD'}),
        ('read-data', {'WORKLOAD': 'read_incr8'}), ('read-strobe', {'WORKLOAD': 'read_incr8', 'FAULT_TYPE': 'Control', 'CONTROL_SIGNAL': 'HWSTRB'}),
        ('boolean', {'FAULT_ENABLE': '1'}), ('decimal', {'FAULT_BIT': '0x3'}), ('negative', {'FAULT_TYPE': 'Delay', 'DELAY_CYCLES': -1}),
        ('delay-range', {'FAULT_TYPE': 'Delay', 'DELAY_CYCLES': 129}), ('beat-conflict', {'INJECT_AT_BEAT': 1}),
        ('address-width', {'FAULT_TYPE': 'Address', 'ADDRESS_MODE': 'replace', 'ADDRESS_VALUE': hex(1 << 56)}),
        ('control-width', {'FAULT_TYPE': 'Control', 'CONTROL_SIGNAL': 'HWRITE', 'CONTROL_VALUE': '0x2'}),
        ('cycle-conflict', {'INJECT_AT_CYCLE': 0}), ('cycle-range', {'TRIGGER_MODE': 'cycle', 'INJECT_AT_TRANSACTION': 'none', 'INJECT_AT_CYCLE': 2000}),
        ('idle', {'FAULT_TYPE': 'Control', 'CONTROL_SIGNAL': 'HTRANS', 'CONTROL_VALUE': '0x0'}),
        ('busy-first', {'FAULT_TYPE': 'Control', 'CONTROL_SIGNAL': 'HTRANS', 'CONTROL_VALUE': '0x1', 'INJECT_AT_TRANSACTION': 1, 'INJECT_AT_BEAT': 1}),
    ]
    for name, settings in invalid:
        add('invalid-' + name, settings, 'INVALID_CONFIGURATION')
    add('unknown-key', expected='INVALID_CONFIGURATION', transform=lambda text: text.replace('[fault]', '[fault]\nUNKNOWN = true'))
    add('unknown-section', expected='INVALID_CONFIGURATION', transform=lambda text: text + '\n[unknown]\nVALUE = 1\n')
    add('duplicate-key', expected='INVALID_CONFIGURATION', transform=lambda text: text.replace('FAULT_ENABLE = true', 'FAULT_ENABLE = true\nFAULT_ENABLE = false'))
    results = []
    for index, (name, text, expected, reason) in enumerate(scenarios, 1):
        config = configs / (name + '.ini'); config.write_text(text)
        command = [sys.executable, str(ROOT / 'tests/ahb_lockstep/run_f3c.py'), '--config', str(config), '--artifacts-root', str(cases_root)]
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=300)
        (run / (name + '.log')).write_text(result.stdout + result.stderr)
        output = Path(next(line.removeprefix('結果目錄: ') for line in result.stdout.splitlines() if line.startswith('結果目錄: ')))
        summary = json.loads((output / 'summary.json').read_text())
        observed = summary['result'] if expected.startswith('DELAY_') else summary['status']
        passed = observed == expected and ((result.returncode == 0) == (expected in ('PASS', 'DELAY_VERIFIED', 'DELAY_ZERO_VERIFIED')))
        if reason is not None:
            passed = passed and summary.get('INJECTION_APPLIED') and summary.get('FAULT_DETECTED') and int(summary['tb']['compare_reason'], 16) == 1 << reason
        if expected == 'NO_EFFECT':
            passed = passed and not summary['INJECTION_APPLIED'] and not summary['FAULT_DETECTED']
        if expected == 'INVALID_CONFIGURATION':
            passed = passed and '設定錯誤' in result.stderr
        if name == 'wave-disabled':
            passed = passed and not (output / 'f3c-fault.fst').exists()
        record = {'case': name, 'expected': expected, 'observed': observed, 'exit_code': result.returncode, 'status': 'PASS' if passed else 'FAIL', 'evidence': str(output), 'command': command}
        results.append(record)
        dump(run / f'case-{index:03d}.json', record)
        print(f'{index}/{len(scenarios)} {name}: {record["status"]}', flush=True)
        if not passed:
            dump(run / 'summary.json', {'status': 'FAIL', 'tests': results}); return 1
    dump(run / 'summary.json', {'status': 'PASS', 'cases': len(results), 'tests': results, 'full_F2_acceptance_complete': False})
    return 0


if __name__ == '__main__':
    sys.exit(main())
