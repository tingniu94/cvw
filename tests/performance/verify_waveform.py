#!/usr/bin/env python3
"""Independent pre-edge VCD replay of ROI, retirement, stalls and bus beats."""
import argparse
import hashlib
import json
from collections import Counter
from pathlib import Path


def verify(directory):
    directory=directory.resolve()
    expected=json.loads((directory/'performance.json').read_text())
    path=directory/'testbench.vcd'
    wanted={x:'testbench.'+x for x in ['clk','reset','reset_ext','TestBenchReset','CurrState','TestComplete','HRESETn','HREADY','HTRANS','HADDR','HWRITE','HBURST']}
    wanted['HRESP']='testbench.dut.HRESP'
    for x in 'FDEMW':
        wanted['stall_'+x.lower()+'_cycles']='testbench.dut.core.Stall'+x
    wanted['retire']='testbench.dut.core.priv.priv.csr.InstrValidNotFlushedM'
    reverse={v:k for k,v in wanted.items()}
    ids={};stack=[];values={};changes={};now=0
    seen_reset=False;active=False;done=False;pending=None;start=None;end=None
    stats=Counter();histogram=Counter();transactions=[];transitions=[];edge=0
    with path.open() as f:
        for line in f:
            s=line.split()
            if not s:continue
            if s[0]=='$scope':stack.append(s[2])
            elif s[0]=='$upscope':stack.pop()
            elif s[0]=='$var':
                name='.'.join(stack+[s[4]])
                if name in reverse: ids[reverse[name]]=s[3]
            elif s[0]=='$enddefinitions':break
        assert set(ids)==set(wanted),set(wanted)-set(ids)
        codes=set(ids.values())

        def flush():
            nonlocal seen_reset,active,done,pending,start,end,edge
            old=values.copy(); values.update(changes)
            for name in ['TestBenchReset','reset_ext','reset','TestComplete']:
                code=ids[name]
                if code in old and old[code]!=values[code]:
                    transitions.append({'time_ps':now,'signal':name,'value':int(values[code],2)})
            if old.get(ids['clk'],'0')=='1' or values.get(ids['clk'])!='1':return
            edge+=1
            # VCD dumps the final time-slot state. Use previous time slot for
            # everything except recognizing the clock transition itself.
            v={name:int(old.get(code,values[code]),2) for name,code in ids.items()}
            if done:return
            if v['reset']:
                seen_reset=True
                assert not active,'Unexpected CPU reset in baseline'
                return
            if not seen_reset:return
            if not active:active=True;start=now
            # RUN_TEST is enum index 6 in both identical baseline testbenches.
            if v['CurrState']==6 and v['TestComplete']:
                end=now;done=True;return
            stats['cpu_cycles']+=1
            stats['retired_instructions']+=v['retire']
            stall_keys=['stall_'+x.lower()+'_cycles' for x in 'FDEMW']
            stats['pipeline_any_stall_cycles']+=int(any(v[x] for x in stall_keys))
            for key in stall_keys:stats[key]+=v[key]
            if not v['HRESETn']:
                stats['ahb_cancelled_beats']+=int(pending is not None)
                pending=None;return
            if pending is not None:
                if not v['HREADY']:
                    stats['ahb_stall_cycles']+=1;pending['waits']+=1
                else:
                    latency=edge-pending['edge']
                    assert latency==1+pending['waits']
                    pending.update(completion_time_ps=now,latency_cycles=latency,error=v['HRESP'])
                    transactions.append(pending)
                    stats['ahb_completed_beats']+=1
                    stats['ahb_write_beats' if pending['write'] else 'ahb_read_beats']+=1
                    stats['ahb_error_beats']+=v['HRESP']
                    stats['ahb_latency_sum']+=latency
                    stats['ahb_completed_wait_cycles']+=pending['waits']
                    histogram[latency]+=1
                    pending=None
            if v['HREADY'] and v['HTRANS']&2:
                stats['ahb_accepted_beats']+=1
                pending={'accept_time_ps':now,'edge':edge,'addr':v['HADDR'],
                         'write':v['HWRITE'],'burst':v['HBURST'],'waits':0}

        for line in f:
            line=line.strip()
            if not line:continue
            if line[0]=='#':flush();changes={};now=int(line[1:])
            elif line[0] in 'bB':
                val,code=line[1:].split()
                if code in codes:changes[code]=val
            elif line[0] in '01xXzZ' and line[1:] in codes:changes[line[1:]]=line[0]
        flush()
    assert done
    stats['pending_at_end']=int(pending is not None)
    stats['ahb_latency_min']=min(histogram) if histogram else 0
    stats['ahb_latency_max']=max(histogram) if histogram else 0
    assert expected['start_time']==start and expected['end_time']==end
    for key,val in stats.items():assert expected[key]==val,(key,val,expected[key])
    # Check zero-count metrics too (Counter missing keys have implicit zero).
    for key in ['ahb_error_beats','ahb_cancelled_beats']:
        assert expected[key]==stats[key]
    result={'status':'PASS','start_time_ps':start,'end_time_ps':end,
            'replayed_metrics':dict(stats),'latency_histogram':dict(histogram),
            'reset_and_completion_transitions':transitions,
            'vcd_sha256':hashlib.sha256(path.read_bytes()).hexdigest()}
    with (directory/'waveform-verification.json').open('x') as out:
        json.dump(result,out,indent=2);out.write('\n')
    with (directory/'roi-transactions.json').open('x') as out:
        json.dump(transactions,out,indent=2);out.write('\n')
    print('WAVEFORM_VERIFICATION_PASS',directory)


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('runtime_directory',type=Path)
    args=parser.parse_args()
    verify(args.runtime_directory)
