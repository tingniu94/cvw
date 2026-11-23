"""原始rv64gc EBU/IFU/LSU Compatibility Gate;拒絕覆蓋結果。"""
import hashlib
import subprocess
import sys
from pathlib import Path

from run_alignment import dump, execute

ROOT=Path(__file__).resolve().parents[2]
run=Path(sys.argv[1]).resolve();run.mkdir(parents=True,exist_ok=False)
sources=['src/cvw.sv']+['src/ebu/ahb_lockstep_'+n+'.sv' for n in ['ingress','pair','dual_ingress','compare','burst_context','output','guard']]
sources += ['src/ebu/ebu.sv','src/ebu/ebufsmarb.sv','src/ebu/controllerinput.sv','src/generic/counter.sv','src/generic/flop/flopenl.sv','src/generic/flop/flopr.sv','src/ebu/ahbcacheinterface.sv','src/ebu/buscachefsm.sv','src/lsu/swbytemask.sv']
sources += ['src/generic/flop/'+n+'.sv' for n in ['flopen','flopenr']]+['src/generic/mux.sv','tests/ahb_lockstep/ebu_gate_tb.sv']
files=sources+['config/rv64gc/config.vh','config/shared/config-shared.vh','config/shared/parameter-defs.vh','config/shared/BranchPredictorType.vh','tests/ahb_lockstep/run_ebu_gate.py']
snap=run/'source-snapshot'
for f in files:
 p=snap/f;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((ROOT/f).read_bytes())
dump(run/'source-sha256.json',{f:hashlib.sha256((ROOT/f).read_bytes()).hexdigest() for f in files})
dump(run/'safety-sha256.json',{f:hashlib.sha256((ROOT/f).read_bytes()).hexdigest() for f in ['tests/riscof/config.ini','docs/meeting-progress-log.md','docs/ahb-dual-core-step3f-f2.md']})
(run/'meeting-before.md').write_bytes((ROOT/'docs/meeting-progress-log.md').read_bytes())
dump(run/'environment.json',{k:subprocess.check_output(v,text=True).strip() for k,v in {
 'verilator':['verilator','--version'],'branch':['git','branch','--show-current'],'head':['git','rev-parse','HEAD'],'status':['git','status','--short'],'history':['git','log','--oneline','-6']}.items()})
base=['verilator','--timing','--assert','--timescale','1ps/1ps','--top-module','ebu_gate_tb','-I'+str(ROOT/'config/rv64gc'),'-I'+str(ROOT/'config/shared')]
results={}
for name in ['ebu']:
 params=[]
 execute(run,name+'-lint',base+['--lint-only']+params+[str(ROOT/f) for f in sources],ROOT)
 execute(run,name+'-build',base+['--binary','--trace-fst','--Mdir',str(run/('work-'+name))]+params+[str(ROOT/f) for f in sources],ROOT)
 rt=run/name;rt.mkdir()
 execute(run,name+'-simulation',[str(run/('work-'+name)/'Vebu_gate_tb')],rt)
 log=(run/(name+'-simulation.log')).read_text();assert 'EBU_GATE_PASS' in log
 assert '%Warning' not in (run/(name+'-build.log')).read_text()
 results[name]={'status':'PASS','result':next(s for s in log.splitlines() if 'EBU_GATE_PASS' in s)}
dump(run/'summary.json',{'status':'PASS','scope':'原始EBU/IFU/LSU Controller+Guard,不是真CPU或Uncore','tests':results,'full_F2_acceptance_complete':False,'build_warnings':0})
print('EBU_GATE_PASS',run/'summary.json')
