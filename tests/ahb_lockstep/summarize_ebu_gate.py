"""獨立EBU CSV/FST重播:IFU/LSU Owner、Cache Ack與Fetch Buffer。"""
import bisect
import csv
import hashlib
import json
import sys
from pathlib import Path

from run_alignment import dump, execute

ROOT=Path(__file__).resolve().parents[2]
run=Path(sys.argv[1]).resolve()
summary=json.loads((run/'summary.json').read_text());assert summary['status']=='PASS'
results={}
for name in summary['tests']:
 rt=run/name
 execute(run,name+'-fst-export',['fst2vcd','-f',str(rt/'ebu-gate.fst'),'-o',str(rt/'ebu-gate-export.vcd')],ROOT)
 scopes=[];codes={};changes={};widths={};header=True;now=0
 for line in (rt/'ebu-gate-export.vcd').read_text().splitlines():
  p=line.split()
  if not p:continue
  if p[0]=='$scope':scopes.append(p[2])
  elif p[0]=='$upscope':scopes.pop()
  elif p[0]=='$var' and scopes==['ebu_gate_tb']:
   codes[p[3]]=p[4];changes[p[4]]=[];widths[p[4]]=int(p[2])
  elif p[0]=='$enddefinitions':header=False
  elif not header:
   if line[0]=='#':now=int(line[1:])
   elif line[0] in 'bB':
    val,code=line[1:].split()
    if code in codes:changes[codes[code]].append((now,val))
   elif line[0] in '01xXzZ' and line[1:] in codes:changes[codes[line[1:]]].append((now,line[0]))
 times={n:[t for t,_ in vals] for n,vals in changes.items()}
 def sample(n,t,times=times,changes=changes):
  idx=bisect.bisect_right(times[n],t)-1;assert idx>=0,n
  return int(changes[n][idx][1],2)
 rows=list(csv.DictReader((rt/'events.csv').open()))
 records=[];slots=[None,None];need=[False,False];seq=[0,0];pair_queue=[];current=None;bursts=[];acks=[]
 for row in rows:
  assert None not in row
  if row['resetn']=='0':continue
  c=int(row['cycle']);t=int(row['time_ps'])
  def bit(k, row=row):
      return row[k] == '1'
  row['m_write']=sample('M_HWRITE',t-1)
  for side in [0,1]:
   if need[side]:
    slots[side]['wdata']=int(row[['a_wdata','b_wdata'][side]],16)
    slots[side]['wstrb']=int(row[['a_strb','b_strb'][side]],16);need[side]=False
  if bit('pair_valid') and bit('pair_ready'):
   assert all(slots) and not any(need)
   a,b=slots;assert a['seq']==b['seq']
   for field in ['addr','write','size','burst','trans','prot','origin']:assert a[field]==b[field],field
   if a['write']:assert a['wdata']==b['wdata'] and a['wstrb']==b['wstrb']
   pair_queue.append({'seq':a['seq'],'request':dict(a),'pair_cycle':c})
  if bit('match_valid') and bit('match_ready'):
   assert bit('authorized') and pair_queue and current is None
   current=pair_queue.pop(0);current.update(match_cycle=c,authorization_cycle=c)
  if bit('down_accept'):
   assert current is not None and 'accept_cycle' not in current and bit('m_ready')
   req=current['request'];assert int(row['owner'])==current['seq']
   assert int(row['m_addr'],16)==req['addr'] and row['m_write']==req['write']
   assert sample('M_HPROT',t-1)==req['prot']
   assert int(row['m_burst'])==req['burst'] and int(row['m_trans'],2)==req['trans'] and int(row['m_size'])==req['size']
   current.update(accept_cycle=c,case=row['case'].strip())
   if req['burst']==5:
    if req['trans']==2:
     assert not bursts or len(bursts[-1]['owners'])==8
     bursts.append({'id':len(bursts),'base':req['addr'],'origin':req['origin'],'write':req['write'],'owners':[]})
    b=bursts[-1];assert len(b['owners'])<8 and req['addr']==b['base']+8*len(b['owners'])
    current['burst_id']=b['id'];current['beat_index']=len(b['owners']);b['owners'].append(current)
    assert req['origin']==b['origin']
  if bit('down_complete'):
   assert current is not None and 'accept_cycle' in current and 'data_complete_cycle' not in current
   current.update(data_complete_cycle=c,hrdata=int(row['m_rdata'],16),hresp=int(row['m_resp']),
                  hwdata=int(row['m_wdata'],16),hwstrb=int(row['m_strb'],16))
   assert not current['hresp'] and c>current['accept_cycle']
   if current['request']['write']:
    assert current['hwdata']==current['request']['wdata'] and current['hwstrb']==current['request']['wstrb']
  if bit('a_capture') or bit('b_capture'):
   assert bit('a_capture') and bit('b_capture') and current and 'data_complete_cycle' in current
   assert 'response_capture_cycle' not in current;current['response_capture_cycle']=c
  if bit('a_complete') or bit('b_complete'):
   assert bit('a_complete') and bit('b_complete') and current and 'response_capture_cycle' in current
   for side in [0,1]:assert sample('rd['+str(side)+']',t-1)==current['hrdata']
   current['a_complete_cycle']=c;current['b_complete_cycle']=c
   for side,key in enumerate(['a_ack','b_ack']):
    if bit(key):
     assert current['request']['burst']==5 and current['beat_index']==7
     b=bursts[current['burst_id']];assert len(b['owners'])==8
     assert all('data_complete_cycle' in o for o in b['owners'])
     record={'side':side,'burst_id':b['id'],'origin':b['origin'],'write':b['write'],'ack_cycle':c,'ack_time_ps':t,
             'last_down_complete_cycle':current['data_complete_cycle']}
     assert c>current['data_complete_cycle']
     if not b['write']:
      assert sample('cack['+str(side)+']['+str(b['origin'])+']',t-1)==1
      fb=sample('cfetch['+str(side)+']['+str(b['origin'])+']',t)
      expected=sum(o['hrdata']<<(64*j) for j,o in enumerate(b['owners']))
      assert fb==expected,'Fetch Buffer order'
      record.update(fetch_buffer=f'{fb:0128x}',expected_buffer=f'{expected:0128x}',fetch_order_match=True)
     acks.append(record)
   records.append(current);current=None;slots=[None,None]
  else:assert not bit('a_ack') and not bit('b_ack')
  for side,key in enumerate(['a_accept','b_accept']):
   if bit(key):
    assert slots[side] is None
    pre=t-1
    slots[side]={'seq':seq[side],'addr':int(row[['a_addr','b_addr'][side]],16),
     'origin':sample('prot['+str(side)+']',pre)&1,'prot':sample('prot['+str(side)+']',pre),
     'write':sample('wr['+str(side)+']',pre),'size':sample('size['+str(side)+']',pre),
     'burst':sample('burst['+str(side)+']',pre),'trans':sample('trans['+str(side)+']',pre),
     'up_accept_cycle':c}
    seq[side]+=1;need[side]=bool(slots[side]['write'])
 assert current is None and not any(slots) and not pair_queue
 expected_count=236
 assert len(records)==expected_count and len({o['seq'] for o in records})==expected_count
 assert len(acks)==56
 assert all(len(b['owners'])==8 for b in bursts)
 def selected(predicate, rows=rows):return [r for r in rows if r['resetn']=='1' and predicate(r)]
 stats={'status':'PASS','completed_owners':len(records),'cache_bursts':len(bursts),
  'ifu_beats':sum(o['request']['origin']==0 for o in records),
  'lsu_beats':sum(o['request']['origin']==1 for o in records),
  'ifu_refill_bursts':sum(b['origin']==0 for b in bursts),
  'lsu_refill_bursts':sum(b['origin']==1 and not b['write'] for b in bursts),
  'lsu_writeback_bursts':sum(b['origin']==1 and b['write'] for b in bursts),
  'read_refill_bursts':sum(not b['write'] for b in bursts),'writeback_bursts':sum(b['write'] for b in bursts),
  'ack_A':sum(a['side']==0 for a in acks),'ack_B':sum(a['side']==1 for a in acks),
  'fetch_buffer_snapshots_verified':sum('fetch_order_match' in a for a in acks),
  'busy_cycles':len(selected(lambda r:r['m_trans']=='01')),
  'address_stall_cycles':len(selected(lambda r:r['address_phase']=='1' and r['m_ready']=='0')),
  'data_stall_cycles':len(selected(lambda r:r['data_phase']=='1' and r['m_ready']=='0')),
  'peer_wait_cycles':len(selected(lambda r:r['a_req']!=r['b_req'])),
  'pair_backpressure_cycles':len(selected(lambda r:r['pair_valid']=='1' and r['pair_ready']=='0')),
  'consumer_backpressure_cycles':len(selected(lambda r:r['match_valid']=='1' and r['match_ready']=='0')),
  'downstream_overlap_edges':len(selected(lambda r:r['down_accept']=='1' and r['down_complete']=='1')),
  'last_data_pending_stall_cycles':len(selected(lambda r:r['data_phase']=='1' and r['m_burst']=='5' and r['m_trans']=='00' and r['m_ready']=='0')),
  'beat_latency_min':min(o['data_complete_cycle']-o['accept_cycle'] for o in records),
  'beat_latency_max':max(o['data_complete_cycle']-o['accept_cycle'] for o in records),
  'controller_cycles_total':int(rows[-1]['cycle'])-3}
 burststats=[]
 for b in bursts:
  first,last=b['owners'][0],b['owners'][-1]
  burststats.append({'id':b['id'],'base':b['base'],'write':b['write'],
   'first_up_accept_cycle':first['request']['up_accept_cycle'],'last_a_complete_cycle':last['a_complete_cycle'],
   'controller_window_cycles_inclusive':last['a_complete_cycle']-first['request']['up_accept_cycle']+1,
   'downstream_address_to_last_data_cycles':last['data_complete_cycle']-first['accept_cycle'],
   'last_data_cycle':last['data_complete_cycle'],'ack_cycle':last['a_complete_cycle']})
 dump(rt/'events.json',rows);dump(rt/'beat-ledger.json',records);dump(rt/'ack-fetch-ledger.json',acks)
 dump(rt/'burst-metrics.json',burststats);dump(rt/'metrics.json',stats)
 results[name]=stats
 dump(rt/'cases.json',list(csv.DictReader((rt/'cases.csv').open())))
dump(run/'verification.json',{'status':'PASS','scope':'原始EBU/Controllers/Guard,不是真CPU CPI或SoC驗證',
                             'full_F2_acceptance_complete':False,'tests':results})
for f in ['tests/ahb_lockstep/summarize_ebu_gate.py']:
 p=run/'source-snapshot'/f;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((ROOT/f).read_bytes())
dump(run/'analysis-source-sha256.json',{'tests/ahb_lockstep/summarize_ebu_gate.py':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()})
print(json.dumps(results,indent=2))
