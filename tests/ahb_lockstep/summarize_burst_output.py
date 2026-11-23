"""Read-only CSV replay; create additional F2 evidence without rerunning simulation."""
import csv
import hashlib
import json
import sys
from pathlib import Path

from run_alignment import dump

run=Path(sys.argv[1]).resolve()
summary=json.loads((run/'summary.json').read_text());assert summary['status']=='PASS'
result={}
for name in summary['tests']:
    runtime=run/name
    rows=list(csv.DictReader((runtime/'guard-events.csv').open()))
    pairs=[];active=None;records=[];epoch=0;was_reset=True
    for row in rows:
        def bit(k, row=row):
            return row[k] == '1'
        cycle=int(row['cycle'])
        if not bit('resetn'):
            assert active is None
            pairs=[];was_reset=True
            continue
        if was_reset:epoch+=1;was_reset=False
        if bit('pair_valid') and bit('pair_ready'):pairs.append(cycle)
        if bit('match_valid') and bit('match_ready'):
            assert pairs
            pair_cycle=pairs.pop(0)
            if bit('authorized'):
                assert active is None and not bit('fault')
                active={'epoch':epoch,'pair_cycle':pair_cycle,'match_cycle':cycle,'authorized_cycle':cycle}
            else:assert bit('policy_reject')
        if int(row['down_trans'],2)&2:
            assert active is not None
        if bit('down_accept'):
            assert active is not None and 'accept_cycle' not in active and bit('down_ready')
            active.update(accept_cycle=cycle,owner_seq=int(row['owner_seq']),
                          address=row['down_addr'],htrans=row['down_trans'],hburst=int(row['down_burst']),
                          hsize=int(row['down_size']),hwrite=bit('down_write'))
        if bit('down_complete'):
            assert active is not None and 'accept_cycle' in active and 'complete_cycle' not in active
            assert cycle>active['accept_cycle']
            active.update(complete_cycle=cycle,hwdata=row['down_wdata'],hwstrb=row['down_strb'],
                          hrdata=row['down_rdata'],hresp=bit('down_resp'))
        if bit('a_rsp_capture') or bit('b_rsp_capture'):
            assert bit('a_rsp_capture') and bit('b_rsp_capture') and active is not None
            assert 'complete_cycle' in active and 'capture_cycle' not in active
            active['capture_cycle']=cycle
        if bit('a_complete') or bit('b_complete'):
            assert bit('a_complete') and bit('b_complete') and active is not None
            assert 'capture_cycle' in active
            active['a_complete_cycle']=cycle;active['b_complete_cycle']=cycle
            records.append(active);active=None
    assert active is None and len(records)==37
    assert len({(r['epoch'],r['owner_seq']) for r in records})==37
    stats={'completed_records':len(records),'busy_cycles':sum(r['down_trans']=='01' for r in rows),
           'address_stall_cycles':sum(r['address_phase']=='1' and r['down_ready']=='0' for r in rows),
           'data_stall_cycles':sum(r['data_phase']=='1' and r['down_ready']=='0' for r in rows),
           'upstream_overlap_edges':sum(r['a_complete']=='1' and r['a_accept']=='1' for r in rows),
           'downstream_overlap_edges':sum(r['down_complete']=='1' and r['down_accept']=='1' for r in rows),
           'beat_latency_min':min(r['complete_cycle']-r['accept_cycle'] for r in records),
           'beat_latency_max':max(r['complete_cycle']-r['accept_cycle'] for r in records)}
    assert stats['downstream_overlap_edges']==0 and stats['upstream_overlap_edges']==2
    dump(runtime/'events.json',rows)
    dump(runtime/'beat-ledger.json',records)
    dump(runtime/'replay-summary.json',stats)
    result[name]=stats
source=Path(__file__).resolve()
dump(run/'replay-summary.json',{'status':'PASS','method':'independent CSV ownership/handshake replay','widths':result,
                              'analysis_source':str(source),'analysis_sha256':hashlib.sha256(source.read_bytes()).hexdigest()})
(run/'source-snapshot'/source.name).write_bytes(source.read_bytes())
print(json.dumps(result,indent=2))
