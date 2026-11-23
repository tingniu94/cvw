"""以原始FST/CSV獨立核對EBU仲裁與IFU Save/Restore,不變更模擬。"""
import bisect
import csv
import hashlib
import json
import sys
from pathlib import Path

from run_alignment import dump

r=Path(sys.argv[1]).resolve();rt=r/'ebu'
scopes=[];names={};widths={};values={};header=True;t=0
for line in (rt/'ebu-gate-export.vcd').read_text().splitlines():
 p=line.split()
 if not p:continue
 if p[0]=='$scope':scopes.append(p[2])
 elif p[0]=='$upscope':scopes.pop()
 elif p[0]=='$var':
  name='.'.join(scopes+[p[4]]);names[name]=p[3];widths[name]=int(p[2]);values.setdefault(p[3],[])
 elif p[0]=='$enddefinitions':header=False
 elif not header:
  if line[0]=='#':t=int(line[1:])
  elif line[0] in 'bB':
   val,code=line[1:].split()
   if code in values:values[code].append((t,val))
  elif line[0] in '01xz' and line[1:] in values:values[line[1:]].append((t,line[0]))
times={c:[t for t,_ in vals] for c,vals in values.items()}
def get(name,t):
 code=names[name];i=bisect.bisect_right(times[code],t)-1;assert i>=0,name
 return int(values[code][i][1],2)
rows=list(csv.DictReader((rt/'arbitration.csv').open()));windows=[];saved=[None,None];stats=[]
for side in [0,1]:
 data=[v for v in rows if int(v['replica'])==side];save_count=restore_cycles=held_advancing=0
 for row in data:
  t=int(row['time_ps']);state=int(row['state'],2);nxt=int(row['next_state'],2)
  def bit(k, row=row):
      return row[k] == '1'
  both=bit('ifu_req') and bit('lsu_req')
  assert nxt==(1 if both else 0) if state==0 else nxt==(0 if bit('guard_ready') and bit('final_beat_d') and not both else 1)
  assert bit('restore')==(state==1) and bit('ifu_disable')==bit('restore')
  assert bit('ifu_ready')==(bit('guard_ready') and not bit('ifu_disable'))
  assert bit('lsu_ready')==(bit('guard_ready') and not bit('lsu_disable'))
  prefix=f'ebu_gate_tb.replicas[{side}].original_ebu.'
  if bit('save'):
   assert state==0 and both and bit('lsu_select') and not bit('ifu_select') and saved[side] is None
   fields={out:get(prefix+inp,t-1) for inp,out in [('IFUHADDR','IFUHADDROut'),('IFUHSIZE','IFUHSIZEOut'),('IFUHBURST','IFUHBURSTOut'),('IFUHTRANS','IFUHTRANSOut')]}
   saved[side]={'side':side,'save_time_ps':t,'fields':fields,'restore_cycles':0};save_count+=1
  if bit('restore'):
   restore_cycles+=1;assert saved[side] is not None
   for name,v in saved[side]['fields'].items():assert get(prefix+name,t-1)==v,(side,t,name)
   saved[side]['restore_cycles']+=1
   if int(row['ifu_addr'],16)!=saved[side]['fields']['IFUHADDROut']:held_advancing+=1
  # On the final LSU data completion edge, selected saved IFU address may
  # be accepted while the original IFU controller still has ready=0.
  if bit('guard_ready') and int(row['ebu_trans'],2)&2 and get('ebu_gate_tb.prot['+str(side)+']',t-1)==2 and saved[side] is not None:
   assert int(row['ebu_addr'],16)==saved[side]['fields']['IFUHADDROut']
   saved[side]['saved_address_forwarded_time_ps']=t;windows.append(saved[side]);saved[side]=None
 assert saved[side] is None
 stats.append({'side':side,'save_events':save_count,'restore_cycles':restore_cycles,'cycles_saved_address_differs_from_live_ifu':held_advancing})
ledger=json.loads((rt/'beat-ledger.json').read_text())
# Actual writeback line readback, not simply a new-address Read.
wb=[v for v in ledger if v['case']=='lsu_write_zero'];rb=[v for v in ledger if v['case']=='lsu_writeback_readback']
assert len(wb)==len(rb)==8
for a,b in zip(wb,rb):assert a['request']['addr']==b['request']['addr'] and a['hwdata']==b['hrdata']
byte_writes=[v for v in ledger if v['case'].startswith('uncached_byte_')]
assert len(byte_writes)==8
expected=0
for v in byte_writes:
 lane=v['request']['addr']%8
 assert v['hwstrb']==1<<lane and v['request']['addr']&~7==3584
 expected|=((v['hwdata']>>(8*lane))&255)<<(8*lane)
last=next(v for v in ledger if v['case']=='uncached_readback')
assert last['request']['addr']==3584 and last['hrdata']==expected
assert (rt/'memory-actual.hex').read_bytes()==(rt/'memory-expected.hex').read_bytes()
assert len((rt/'memory-actual.hex').read_text().splitlines())==4096
ack=json.loads((rt/'ack-fetch-ledger.json').read_text());assert {v['ack_cycle']-v['last_down_complete_cycle'] for v in ack}=={2}
dump(rt/'arbitration-events.json',rows);dump(rt/'save-restore-ledger.json',windows)
result={'status':'PASS','replicas':stats,'saved_requests_forwarded_once':len(windows),
        'writeback_readback_words_verified':8,'uncached_byte_lanes_verified':8,'uncached_readback':hex(expected),
        'final_memory_bytes_verified':4096,'ack_after_last_downstream_data_cycles':2,
        'full_F2_acceptance_complete':False}
dump(r/'arbitration-verification.json',result)
src=Path(__file__);p=r/'source-snapshot/tests/ahb_lockstep'/src.name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(src.read_bytes())
dump(r/'arbitration-analysis-sha256.json',{str(src):hashlib.sha256(src.read_bytes()).hexdigest()})
print(json.dumps(result,indent=2))
