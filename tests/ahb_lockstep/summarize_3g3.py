"""Replay pre-NBA CPU/AHB samples and compare versioned performance ROIs."""
import argparse
import csv
import hashlib
import json
from collections import Counter
from pathlib import Path
from statistics import mean

COMMON = 'reset_release_to_retired_tohost_and_drained_v1'
LEGACY = 'reset_release_to_tb_complete_v1'


def read_csv(path):
    with path.open() as stream:
        return list(csv.DictReader(stream))


def write_csv(path, entries):
    assert entries
    fields = list(dict.fromkeys(key for row in entries for key in row))
    with path.open('x') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(entries)


def dump(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')


def stats(values):
    return {'count': len(values), 'average': mean(values) if values else None,
            'minimum': min(values) if values else None, 'maximum': max(values) if values else None,
            'sum': sum(values)}


def cpu_metrics(rows, end, stalls_out, mode):
    active = rows[:end]
    assert all(int(row['cycle']) == i for i, row in enumerate(rows))
    assert all(int(row['time_ps']) - int(rows[i - 1]['time_ps']) == 10
               for i, row in enumerate(rows[1:], 1))
    assert len(active) == end
    retirement = [row for row in active if row['retire'] == '1']
    hosts = [row for row in active if row['tohost'] == '1']
    assert len(hosts) == 1 and hosts[0]['retire'] == '1'
    host_cycle = int(hosts[0]['cycle'])
    csr_mismatches = [0, 0]
    for edge, new in enumerate(rows[1:end + 1]):
        old = rows[edge]
        flags = int(old['csr_flags'], 2)
        for index, field in enumerate(['mcycle', 'minstret']):
            increment = 1 if index == 0 else int(old['retire'])
            if not flags & (1 << (index + 2)):
                expected = (int(old[field], 16) + (0 if flags & (1 << index) else increment)) % (1 << 64)
                csr_mismatches[index] += int(expected != int(new[field], 16))
    assert csr_mismatches == [0, 0]
    csr = {'step_mismatches': csr_mismatches}
    for index, field in enumerate(['mcycle', 'minstret']):
        csr[field + '_inhibited_edges'] = sum(bool(int(row['csr_flags'], 2) & (1 << index)) for row in active)
        csr[field + '_write_edges'] = sum(bool(int(row['csr_flags'], 2) & (1 << (index + 2))) for row in active)
        csr[field + '_delta'] = (int(rows[end][field], 16) - int(rows[0][field], 16)) % (1 << 64)
        valid = not (csr[field + '_inhibited_edges'] or csr[field + '_write_edges'])
        csr[field + '_delta_valid'] = valid
        if valid:
            assert csr[field + '_delta'] == (end if index == 0 else len(retirement))
    counts = {}
    for field, names in [('stalls', ['StallF', 'StallD', 'StallE', 'StallM', 'StallW']),
                         ('memory_stalls', ['ICacheStallF', 'DCacheStallM', 'IFUStallF', 'LSUStallM'])]:
        for bit, name in enumerate(names):
            counts[name] = sum(bool(int(row[field], 2) & (1 << bit)) for row in active)
    counts['pipeline_any'] = sum(int(row['stalls'], 2) != 0 for row in active)
    for name, count in counts.items():
        stalls_out.append({'mode': mode, 'core': rows[0]['core'], 'signal': name,
                           'cycles': count, 'ratio': count / end})
    return {'cycles': end, 'retired_instructions': len(retirement), 'cpi': end / len(retirement),
            'tohost_cycle_0based': host_cycle, 'completion_cycles_inclusive': host_cycle + 1,
            'stalls': counts, 'stall_ratios': {key: value / end for key, value in counts.items()},
            'csr_crosscheck': csr}


def bus_metrics(samples, end, mode, bus, output, burst_output):
    pending = None
    accepted = 0
    completed = []
    burst = None
    groups = []
    wait = busy = address_wait = overlap = 0
    previous = None
    for row in samples:
        edge = int(row['cycle'])
        if edge >= end:
            break
        assert row['hresetn'] == '1'
        ready = row['ready'] == '1'
        trans = int(row['trans'], 2)
        if previous and previous['ready'] == '0':
            for field in ['addr', 'trans', 'burst', 'size', 'write']:
                assert row[field] == previous[field], (mode, bus, edge, field, 'stalled address changed')
        busy += int(trans == 1)
        address_wait += int(bool(trans & 2) and not ready)
        completing = pending is not None and ready
        if pending is not None:
            if pending['write']:
                data = (row['wdata'], row['strb'])
                if 'data' in pending:
                    assert pending['data'] == data, (mode, bus, edge, 'write data changed')
                else:
                    pending['data'] = data
            if ready:
                assert row['resp'] == '0'
                pending['completion'] = edge
                pending['latency'] = edge - pending['acceptance']
                assert pending['latency'] == 1 + pending['wait_cycles']
                pending['rdata'] = row['rdata']
                completed.append(pending)
                if pending['burst_index'] is not None:
                    group = groups[pending['burst_index']]
                    group['completed'] += 1
                    group['last_completion'] = edge
                pending = None
            else:
                pending['wait_cycles'] += 1
                wait += 1
        accepting = ready and bool(trans & 2)
        overlap += int(completing and accepting)
        if accepting:
            addr, size = int(row['addr'], 16), int(row['size'])
            burst_id = None
            if int(row['burst']) == 5:
                if trans == 2:
                    assert burst is None
                    burst = {'mode': mode, 'bus': bus, 'index': len(groups), 'acceptance': edge,
                             'first_address': addr, 'size': size, 'write': int(row['write']), 'accepted': 0, 'completed': 0}
                    groups.append(burst)
                assert burst is not None and trans == (2 if burst['accepted'] == 0 else 3)
                assert addr == burst['first_address'] + burst['accepted'] * (1 << size)
                assert size == burst['size'] and int(row['write']) == burst['write']
                burst_id = burst['index']
                burst['accepted'] += 1
                if burst['accepted'] == 8:
                    burst = None
            else:
                assert int(row['burst']) == 0 and trans == 2 and burst is None
            pending = {'mode': mode, 'bus': bus, 'sequence': accepted, 'acceptance': edge,
                       'address': row['addr'], 'write': int(row['write']), 'size': size,
                       'burst_index': burst_id, 'wait_cycles': 0}
            accepted += 1
        previous = row
    assert pending is None and burst is None and accepted == len(completed)
    for group in groups:
        assert group['accepted'] == group['completed'] == 8
        group['latency'] = group['last_completion'] - group['acceptance']
    for entry in completed:
        data = entry.pop('data', None)
        if data:
            entry['wdata'], entry['strb'] = data
    output.extend(completed)
    burst_output.extend(groups)
    return {'accepted': accepted, 'completed': len(completed), 'pending_at_end': 0,
            'latency': stats([row['latency'] for row in completed]),
            'read_latency': stats([row['latency'] for row in completed if not row['write']]),
            'write_latency': stats([row['latency'] for row in completed if row['write']]),
            'incr8_burst_latency': stats([row['latency'] for row in groups]),
            'data_wait_cycles': wait, 'address_wait_cycles': address_wait, 'busy_cycles': busy,
            'same_edge_completion_acceptance': overlap}


def guard_metrics(rows, end, transactions, bus_samples):
    active = [row for row in rows if int(row['cycle']) < end]
    if not active:
        return None
    def flag(row, field):
        return row[field] == '1'
    definitions = {
        'a_peer_wait': lambda r: flag(r, 'a_offer') and not flag(r, 'b_offer'),
        'b_peer_wait': lambda r: flag(r, 'b_offer') and not flag(r, 'a_offer'),
        'pair_consumer_backpressure': lambda r: flag(r, 'pair_valid') and not flag(r, 'pair_ready'),
        'comparator_result_backpressure': lambda r: flag(r, 'match_valid') and not flag(r, 'match_ready'),
        'a_ingress_no_credit': lambda r: flag(r, 'a_pending') and not flag(r, 'a_complete'),
        'b_ingress_no_credit': lambda r: flag(r, 'b_pending') and not flag(r, 'b_complete'),
        'output_busy_gap': lambda r: flag(r, 'busy_gap'),
        'response_barrier_pending': lambda r: flag(r, 'response_pending'),
    }
    sets = {name: {int(row['cycle']) for row in active if predicate(row)} for name, predicate in definitions.items()}
    downstream = [r for r in transactions if r['mode'] == 'dual' and r['bus'] == 'downstream']
    sets['downstream_data_wait'] = {edge for r in downstream for edge in range(r['acceptance'] + 1, r['completion'])}
    sets['downstream_address_wait'] = {int(r['cycle']) for r in bus_samples if r['bus'] == '2'
                                       and int(r['cycle']) < end and r['ready'] == '0' and int(r['trans'], 2) & 2}
    counts = {name: len(values) for name, values in sets.items()}
    counts['wait_category_union'] = len(set().union(*sets.values()))
    peer = counts['a_peer_wait'] + counts['b_peer_wait']
    assert peer == int(rows[end]['peer_counter']) - int(rows[0]['peer_counter'])
    assert counts['pair_consumer_backpressure'] == int(rows[end]['pair_bp_counter']) - int(rows[0]['pair_bp_counter'])
    pair = [int(r['cycle']) for r in active if flag(r, 'pair_valid') and flag(r, 'pair_ready')]
    match = [int(r['cycle']) for r in active if flag(r, 'match_valid')]
    auth = [int(r['cycle']) for r in active if flag(r, 'auth')]
    down = [r for r in transactions if r['mode'] == 'dual' and r['bus'] == 'downstream']
    assert len(pair) == len(auth) == len(down)
    for stage in ['accept', 'complete']:
        events = [r for r in active if flag(r, stage)]
        assert len(events) == len(down)
        assert all(int(row['owner']) == index for index, row in enumerate(events))
    # First registered MATCH observation belonging to each ordered pair.
    first_match = [next(c for c in match if c > p and c <= a) for p, a in zip(pair, auth)]
    for i, (p, a, transaction) in enumerate(zip(pair, auth, down)):
        transaction['pair'] = p
        transaction['match'] = first_match[i]
        transaction['authorization'] = a
    a_up = [r for r in transactions if r['mode'] == 'dual' and r['bus'] == 'A']
    b_up = [r for r in transactions if r['mode'] == 'dual' and r['bus'] == 'B']
    assert len(a_up) == len(b_up) == len(down)
    for a, b, d in zip(a_up, b_up, down):
        assert a['address'] == b['address'] == d['address'] and a['write'] == b['write'] == d['write']
        assert a['completion'] == b['completion']
        if a['write']:
            assert a['wdata'] == b['wdata'] == d['wdata'] and a['strb'] == b['strb'] == d['strb']
        else:
            assert a['rdata'] == b['rdata'] == d['rdata']
    latencies = {
        'pair_to_registered_match': stats([m - p for p, m in zip(pair, first_match)]),
        'pair_to_authorization': stats([a - p for p, a in zip(pair, auth)]),
        'authorization_to_down_accept': stats([d['acceptance'] - a for d, a in zip(down, auth)]),
        'down_complete_to_core_complete': stats([a['completion'] - d['completion'] for a, d in zip(a_up, down)]),
    }
    return {'wait_cycles': counts, 'latency': latencies,
            'overlap_policy': 'Categories overlap; never sum them as CPU overhead',
            'pairing_wait_cycles': peer,
            'core_facing_response_wait_cycles': {'A': counts['a_ingress_no_credit'], 'B': counts['b_ingress_no_credit']},
            'wait_overlap_cycles': {a + '__' + b: len(sets[a] & sets[b])
                                   for i, a in enumerate(sets) for b in list(sets)[i + 1:]},
            'wait_ratios': {name: value / end for name, value in counts.items()}}



def summarize(run, output):
    output.mkdir(parents=True, exist_ok=False)
    stalls, transactions, bursts = [], [], []
    results = {}
    retirements = {}
    for mode in ['single', 'dual']:
        cpu_rows = read_csv(run / mode / 'cpu-samples.csv')
        core_ids = sorted({row['core'] for row in cpu_rows})
        per_core = [[row for row in cpu_rows if row['core'] == i] for i in core_ids]
        common_end = next(int(row['cycle']) for row in per_core[0] if row['common_end'] == '1')
        legacy_end = next(int(row['cycle']) for row in per_core[0] if row['legacy_end'] == '1')
        assert legacy_end > common_end
        start_time = int(per_core[0][0]['time_ps'])
        common = [cpu_metrics(rows, common_end, stalls, mode) for rows in per_core]
        legacy = [cpu_metrics(rows, legacy_end, [], mode) for rows in per_core]
        assert all(core['tohost_cycle_0based'] < common_end for core in common)
        end_time = int(per_core[0][common_end]['time_ps'])
        assert end_time - start_time == common_end * 10
        old = json.loads((run / mode / 'legacy-performance.json').read_text())
        assert old['roi'] == LEGACY and old['cpu_cycles'] == legacy_end
        assert old['retired_instructions'] == legacy[0]['retired_instructions']
        assert old['start_time'] == start_time and old['end_time'] == int(per_core[0][legacy_end]['time_ps'])
        assert old['csr_cycle_mismatches'] == old['csr_instret_mismatches'] == 0
        ahb = read_csv(run / mode / 'ahb-samples.csv')
        labels = ['single'] if mode == 'single' else ['A', 'B', 'downstream']
        buses = {label: bus_metrics([row for row in ahb if int(row['bus']) == i], common_end, mode, label, transactions, bursts)
                 for i, label in enumerate(labels)}
        # Replay the legacy ROI independently, including its final extra edges.
        legacy_bus = bus_metrics([row for row in ahb if int(row['bus']) == len(labels) - 1], legacy_end, mode, 'legacy', [], [])
        assert old['ahb_accepted_beats'] == legacy_bus['accepted']
        assert old['ahb_completed_beats'] == legacy_bus['completed']
        assert old['ahb_latency_sum'] == legacy_bus['latency']['sum']
        assert old['ahb_stall_cycles'] == legacy_bus['data_wait_cycles']
        guard = guard_metrics(read_csv(run / mode / 'guard-samples.csv'), common_end, transactions, ahb)
        results[mode] = {'roi': COMMON, 'start_cycle': 0, 'end_cycle_exclusive': common_end,
            'start_time_ps': start_time, 'end_time_ps': end_time, 'clock_period_ps': 10,
            'system_cycles': common_end, 'cores': common, 'ahb': buses, 'guard': guard,
            'completion_skew_cycles': max(c['tohost_cycle_0based'] for c in common) - min(c['tohost_cycle_0based'] for c in common),
            'legacy_roi': {'roi': LEGACY, 'end_cycle_exclusive': legacy_end, 'cores': legacy,
                           'original_monitor_crosscheck': 'PASS'}, 'full_F2_acceptance_complete': False}
        retirement = [row for row in cpu_rows if int(row['cycle']) < common_end and row['retire'] == '1']
        retirements[mode] = retirement
        write_csv(output / (mode + '-retirement.csv'), retirement)
        dump(output / (mode + '-performance.json'), results[mode])
    a = [(r['pc'], r['instruction']) for r in retirements['dual'] if r['core'] == '0']
    b = [(r['pc'], r['instruction']) for r in retirements['dual'] if r['core'] == '1']
    assert a == b and len(a) == 4117, 'Changed dual workload retirement requires analysis'
    single_hist = Counter((r['pc'], r['instruction']) for r in retirements['single'])
    dual_hist = Counter(a)
    differences = [{'pc': pc, 'instruction': ins, 'single': single_hist[pc, ins], 'dual': dual_hist[pc, ins],
                    'difference': dual_hist[pc, ins] - single_hist[pc, ins]}
                   for pc, ins in sorted(single_hist.keys() | dual_hist.keys()) if single_hist[pc, ins] != dual_hist[pc, ins]]
    if differences:
        write_csv(output / 'retirement-difference.csv', differences)
    polling = {}
    for mode in ['single', 'dual']:
        core = 'single' if mode == 'single' else 'A'
        reads = [r for r in transactions if r['mode'] == mode and r['bus'] == core
                 and not r['write'] and int(r['address'], 16) == 0x10000005]
        polling[mode + '_uart_lsr_reads'] = len(reads)
    polling['lsr_read_difference'] = polling['dual_uart_lsr_reads'] - polling['single_uart_lsr_reads']
    polling['retirement_pc_differences'] = differences
    polling['disassembly_source'] = str(run / 'inputs/hello.objdump')
    polling['source_reference'] = 'examples/C/common/syscalls.c: uartSend polls UART_LSR bit 5'
    polling['all_retirement_differences_are_poll_loop'] = all(
        int(row['pc'], 16) in (0x80000230, 0x80000234, 0x80000238)
        and row['difference'] == polling['lsr_read_difference'] for row in differences)
    assert polling['all_retirement_differences_are_poll_loop'], 'Unexplained instruction count difference'
    dump(output / 'polling-analysis.json', polling)
    single, dual = results['single'], results['dual']
    comparison = []
    def compare(metric, s, d):
        comparison.append({'metric': metric, 'single': s, 'dual': d, 'difference': d - s,
                           'percentage_change': (d - s) / s * 100 if s else None})
    compare('system_cycles', single['system_cycles'], dual['system_cycles'])
    compare('retired_instructions_per_core', single['cores'][0]['retired_instructions'], len(a))
    compare('cpi', single['cores'][0]['cpi'], dual['cores'][0]['cpi'])
    compare('core_ahb_mean_latency', single['ahb']['single']['latency']['average'], dual['ahb']['A']['latency']['average'])
    compare('downstream_ahb_mean_latency', single['ahb']['single']['latency']['average'], dual['ahb']['downstream']['latency']['average'])
    compare('pipeline_stall_ratio', single['cores'][0]['stall_ratios']['pipeline_any'], dual['cores'][0]['stall_ratios']['pipeline_any'])
    write_csv(output / 'performance-comparison.csv', comparison)
    write_csv(output / 'ahb-latency.csv', transactions)
    write_csv(output / 'burst-latency.csv', bursts)
    write_csv(output / 'stall-counters.csv', stalls)
    write_csv(output / 'guard-wait-counters.csv', [
        {'metric': key, 'cycles': value, 'ratio': dual['guard']['wait_ratios'][key]}
        for key, value in dual['guard']['wait_cycles'].items()])
    write_csv(output / 'guard-stage-latency.csv', [
        {'stage': key, **value} for key, value in dual['guard']['latency'].items()])
    uart_single = (run / 'single/logs/uart.out').read_bytes()
    uart_dual = (run / 'dual/logs/uart.out').read_bytes()
    assert uart_single == uart_dual == b'Hello Wally!\n\r0 1 2 3 4 5 6 7 8 9 \n\r'
    summary = {key: 'PASS' for key in ['SINGLE_HELLO_PASS', 'DUAL_HELLO_PASS', 'RETIREMENT_COUNTER_PASS', 'CYCLE_COUNTER_PASS',
               'CPI_CALCULATION_PASS', 'STALL_COUNTER_PASS', 'AHB_LATENCY_PASS', 'PERFORMANCE_COMPARISON_PASS']}
    summary.update(roi=COMMON, comparison=comparison, full_F2_acceptance_complete=False, F2b='NOT_MET',
                   retirement_differing_pc_count=len(differences), uart_sha256=hashlib.sha256(uart_single).hexdigest(),
                   overhead_scope='Entire dual-core plus Guard architecture; not comparator-only overhead')
    dump(output / 'summary.json', summary)
    print(json.dumps(summary, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    summarize(args.run.resolve(), args.output.resolve())


if __name__ == '__main__':
    main()
