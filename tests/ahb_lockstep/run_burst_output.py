"""F2 controlled INCR8 integration. Always create a new evidence directory."""
import csv
import hashlib
import subprocess
import sys
from pathlib import Path

from run_alignment import dump, execute

ROOT=Path(__file__).resolve().parents[2]
run=Path(sys.argv[1]).resolve();run.mkdir(parents=True,exist_ok=False)
sources=['src/ebu/ahb_lockstep_'+n+'.sv' for n in ['ingress','pair','dual_ingress','compare','burst_context','output','guard']]
files=sources+['tests/ahb_lockstep/burst_output_tb.sv','tests/ahb_lockstep/run_burst_output.py']
snap=run/'source-snapshot';snap.mkdir()
for f in files:(snap/Path(f).name).write_bytes((ROOT/f).read_bytes())
dump(run/'source-sha256.json',{f:hashlib.sha256((ROOT/f).read_bytes()).hexdigest() for f in files})
dump(run/'environment.json',{k:subprocess.check_output(v,text=True).strip() for k,v in {
    'verilator':['verilator','--version'],'head':['git','rev-parse','HEAD'],'branch':['git','branch','--show-current']}.items()})
results={}
for name,aw,dw in [('rv64',56,64),('rv32',34,32),('explicit32',32,32)]:
    cmd=['verilator','--binary','--timing','--trace-fst','--assert','--timescale','1ps/1ps','--top-module','burst_output_tb','--Mdir',str(run/('work-'+name)),f'-GAW={aw}',f'-GDW={dw}']
    cmd += [str(ROOT/f) for f in sources+['tests/ahb_lockstep/burst_output_tb.sv']]
    execute(run,name+'-build',cmd,ROOT)
    runtime=run/name;runtime.mkdir()
    execute(run,name+'-simulation',[str(run/('work-'+name)/'Vburst_output_tb')],runtime)
    log=(run/(name+'-simulation.log')).read_text();assert 'F2_PASS' in log
    assert '%Warning' not in (run/(name+'-build.log')).read_text()
    rows=list(csv.DictReader((runtime/'guard-events.csv').open()))
    totals={key:sum(int(row[key]) for row in rows) for key in ['authorized','down_accept','down_complete','a_complete','b_complete','policy_reject']}
    assert all(totals[k]==37 for k in ['authorized','down_accept','down_complete','a_complete','b_complete'])
    assert totals['policy_reject']==2
    beats=[row for row in rows if row['down_accept']=='1']
    assert sum(int(row['down_burst'])==5 for row in beats)==33
    dump(runtime/'transactions.json',beats)
    results[name]={'status':'PASS','totals':totals,'result':next(x for x in log.splitlines() if x.startswith('F2_PASS'))}
dump(run/'summary.json',{'status':'PASS','scope':'F2 controlled single-outstanding; no downstream pipelining or complete F3 fault policy','build_warnings':0,'tests':results})
print('F2_PASS',run/'summary.json')
