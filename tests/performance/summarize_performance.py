#!/usr/bin/env python3
"""Verify provenance/functional checks, compare without changing test conditions."""
import argparse
import csv
import hashlib
import json
import re
import shutil
from pathlib import Path


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def read(p):
    return json.loads(Path(p).read_text())


def main(run):
    manifests = {}
    metrics = {}
    uart = {}
    failures = []
    checks = {}
    inputs = read(run/'inputs-manifest.json')['files']
    snap = read(run/'instrumentation/manifest.json')
    assert all(sha(run/'instrumentation'/k)==v for k,v in snap['files'].items())
    assert hashlib.sha256(json.dumps(snap['files'],sort_keys=True).encode()).hexdigest()==snap['sha256']
    assert all(sha(run/'inputs'/k)==v for k,v in inputs.items())
    for name in ('original','step2'):
        dest=run/name
        manifests[name]=read(dest/'manifest.json')
        manifest=manifests[name]
        assert manifest['instrumentation_hash']==snap['sha256']
        assert manifest['input_files']==inputs
        assert all(sha(dest/'source'/k)==v for k,v in manifest['instrumented_source_hashes'].items())
        assert sha(dest/'source.tar')==manifest['source_archive_sha256']
        assert sha(dest/'ethernet.tar')==manifest['ethernet_archive_sha256']
        assert read(dest/'build-result.json')['returncode']==0
        assert read(dest/'simulate-result.json')['returncode']==0
        build=(dest/'build.log').read_text()
        log=(dest/'simulate.log').read_text()
        assert not re.search(r'%Warning|%Error|warning:|error:',build), f'{name} build warnings/errors'
        assert not re.search(r'%Fatal|%Error|timeout|timed out|Aborting|Assertion failed',log,re.I), f'{name} runtime failure'
        assert '$finish' in log and 'Single Elf file tests are not signatured verified.' in log
        data=read(dest/'runtime/performance.json')
        assert data['loaded_memfile']==str(run/'inputs/hello.memfile')
        assert data['roi']=='reset_release_to_tb_complete_v1' and data['aborted']==0
        assert data['end_time']-data['start_time']==data['cpu_cycles']*10
        assert data['ahb_accepted_beats']==data['ahb_completed_beats']+data['pending_at_end']+data['ahb_cancelled_beats']
        assert data['ahb_completed_beats']==data['ahb_read_beats']+data['ahb_write_beats']
        assert data['ahb_latency_sum']==data['ahb_completed_beats']+data['ahb_completed_wait_cycles']
        assert data['csr_cycle_mismatches']==data['csr_instret_mismatches']==0
        csr_checks={}
        for prefix,csr,counter in [('cycle','mcycle_delta','cpu_cycles'),('instret','minstret_delta','retired_instructions')]:
            valid=data[f'csr_{prefix}_inhibited_edges']==0 and data[f'csr_{prefix}_write_edges']==0
            csr_checks[prefix]={'raw_delta_valid':valid,'delta':data[csr],'independent_counter':data[counter]}
            if valid:
                assert data[csr]==data[counter],f'{name} CSR delta mismatch'
        uart[name]=(dest/'runtime/logs/uart.out').read_bytes()
        assert b'Hello Wally!' in uart[name] and b'0 1 2 3 4 5 6 7 8 9' in uart[name]
        metrics[name]=data
        checks[name]={'build_warnings':0,'functional':'PASS','roi':'PASS','ahb_conservation':'PASS',
                      'latency_invariant':'PASS','csr':csr_checks,'uart_sha256':sha(dest/'runtime/logs/uart.out'),
                      'loaded_files_sha256':inputs,'source_commit':manifest['source_commit'],
                      'instrumentation_hash':manifest['instrumentation_hash']}
    assert uart['original']==uart['step2'],'UART output differs'
    assert manifests['original']['configuration']==manifests['step2']['configuration']
    # Check numerical agreement for every exported metric, retaining all differences.
    rows=[]
    for key,value in metrics['original'].items():
        if not (isinstance(value,int) or isinstance(value,float)):
            continue
        step=metrics['step2'][key]
        delta=step-value
        percent=delta/value*100 if value else (0.0 if not step else None)
        rows.append({'metric':key,'original':value,'step2':step,'difference':delta,'percentage_overhead':percent})
        if delta:
            failures.append(key)
    result={'status':'PASS' if not failures else 'DIFFERENCE_REQUIRES_ANALYSIS',
            'checks':checks,'uart_identical':True,'differences':failures,'metrics':metrics,'comparison':rows}
    with (run/'performance.json').open('x') as f:
        json.dump(result,f,indent=2);f.write('\n')
    with (run/'performance.csv').open('x',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=['metric','original','step2','difference','percentage_overhead'])
        writer.writeheader();writer.writerows(rows)
    with (run/'comparison.md').open('x') as f:
        f.write('| Metric | Original | Step 2 | Difference | Overhead (%) |\n|---|---:|---:|---:|---:|\n')
        for row in rows:
            f.write('| '+' | '.join(str(row[k]) for k in ['metric','original','step2','difference','percentage_overhead'])+' |\n')
    shutil.copy2(__file__,run/'summarize_performance.py')
    print(result['status'])
    if failures:
        raise SystemExit('Unexplained differences; stop: '+', '.join(failures))


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('run',type=Path)
    args=parser.parse_args()
    main(args.run.resolve())
