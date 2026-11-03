# Extract SoC AHB transitions and pre-edge transactions from a Verilator VCD.
# Usage: python3 extract_bus.py INPUT.vcd OUTPUT_DIRECTORY
import hashlib
import json
import sys
from pathlib import Path

names='HCLK HRESETn HADDR HWDATA HWSTRB HWRITE HSIZE HBURST HPROT HTRANS HMASTLOCK HRDATA HREADY HRESP'.split()
path=Path(sys.argv[1]); out=Path(sys.argv[2]); out.mkdir(exist_ok=True)
ids={}; stack=[]; values={}; timestamp=0; endtime=0; changes=[]
h=hashlib.sha256(); edges=0; stalls=0; reads=0; writes=0; pending=None; tx=[]; reset_edges=0; active_cycle=0
with path.open() as f, (out/'bus-events.txt').open('w') as events:
 for line in f:
  s=line.split()
  if not s: continue
  if s[0]=='$scope': stack.append(s[2])
  elif s[0]=='$upscope': stack.pop()
  elif s[0]=='$var' and stack[-2:]==['testbench','dut'] and s[4] in names: ids[s[4]]=s[3]
  elif s[0]=='$enddefinitions': break
 assert set(ids)==set(names),ids
 codes=set(ids.values())
 def flush():
  global edges,stalls,reads,writes,pending,reset_edges,active_cycle
  oldclk=values.get(ids['HCLK'],'0'); old=values.copy()
  values.update(changes)
  diff=[(n,values.get(ids[n])) for n in names if old.get(ids[n])!=values.get(ids[n])]
  if diff:
   record=json.dumps([timestamp,diff],separators=(',',':'))+'\n'; events.write(record); h.update(record.encode())
  if oldclk!='1' and values.get(ids['HCLK'])=='1':
   edges+=1
   v={n:int(old.get(ids[n],values[ids[n]]),2) for n in names}
   if not v['HRESETn']: pending=None; reset_edges+=1; active_cycle=0; return
   cycle=active_cycle; active_cycle+=1
   if not v['HREADY']:
    if pending: stalls+=1
    return
   if pending:
    pending.update(done_time=timestamp, done_cycle=cycle, waits=cycle-pending['addr_cycle']-1, data=v['HWDATA'] if pending['write'] else v['HRDATA'],resp=v['HRESP'])
    if pending['write']: pending['strb']=v['HWSTRB']; writes+=1
    else: reads+=1
    tx.append(pending)
   pending=dict(addr_time=timestamp,addr_cycle=cycle,addr=v['HADDR'],write=v['HWRITE'],size=v['HSIZE'],burst=v['HBURST'],trans=v['HTRANS'],prot=v['HPROT'],lock=v['HMASTLOCK']) if v['HTRANS']&2 else None
 for line in f:
  line=line.strip()
  if not line: continue
  if line[0]=='#':
   flush(); changes=[]; timestamp=int(line[1:]); endtime=timestamp
  elif line[0] in 'bB':
   val,code=line[1:].split()
   if code in codes: changes.append((code,val))
  elif line[0] in '01xXzZ' and line[1:] in codes: changes.append((line[1:],line[0]))
 flush()
(out/'transactions.json').write_text(json.dumps(tx,indent=2)+'\n')
summary=dict(bus_sha256=h.hexdigest(),end_time_ps=endtime,clock_edges=edges,reset_edges=reset_edges,completed=len(tx),reads=reads,writes=writes,stalled_data_cycles=stalls)
(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n'); print(json.dumps(summary,indent=2))
