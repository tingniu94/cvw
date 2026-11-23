"""F1 standalone validator and real Comparator handoff; immutable new run directory."""
import hashlib
import re
import subprocess
import sys
from pathlib import Path

from run_alignment import dump, execute

ROOT = Path(__file__).resolve().parents[2]
run = Path(sys.argv[1]).resolve()
run.mkdir(parents=True, exist_ok=False)
files = ['src/ebu/ahb_lockstep_burst_context.sv', 'src/ebu/ahb_lockstep_compare.sv',
         'tests/ahb_lockstep/burst_context_tb.sv', 'tests/ahb_lockstep/burst_context_compare_tb.sv',
         'tests/ahb_lockstep/run_burst_context.py']
snapshot = run / 'source-snapshot'
snapshot.mkdir()
for f in files:
    (snapshot / Path(f).name).write_bytes((ROOT / f).read_bytes())
dump(run / 'source-sha256.json', {f: hashlib.sha256((ROOT / f).read_bytes()).hexdigest() for f in files})
dump(run / 'environment.json', {k: subprocess.check_output(v, text=True).strip() for k, v in {
    'verilator': ['verilator', '--version'], 'head': ['git', 'rev-parse', 'HEAD'],
    'branch': ['git', 'branch', '--show-current']}.items()})
results = {}
for name, aw, dw, en in [('rv64',56,64,1), ('rv32',34,32,1), ('explicit32',32,32,1), ('legacy',56,64,0), ('compare',56,64,1)]:
    top = 'burst_context_compare_tb' if name == 'compare' else 'burst_context_tb'
    cmd = ['verilator','--binary','--timing','--trace-fst','--assert','--timescale','1ps/1ps',
           '--top-module',top,'--Mdir',str(run / ('work-'+name))]
    if name != 'compare':
        cmd += [f'-GAW={aw}',f'-GDW={dw}',f"-GENABLE=1'b{en}"]
    cmd += [str(ROOT / files[0]), str(ROOT / ('tests/ahb_lockstep/'+top+'.sv'))]
    if name == 'compare':
        cmd += [str(ROOT / files[1])]
    execute(run,name+'-build',cmd,ROOT)
    runtime = run / name
    runtime.mkdir()
    execute(run,name+'-simulation',[str(run / ('work-'+name) / ('V'+top))],runtime)
    log = (run / (name+'-simulation.log')).read_text()
    assert 'F1_PASS' in log
    assert '%Warning' not in (run / (name+'-build.log')).read_text()
    results[name] = {'status':'PASS','result': re.search(r'F1_PASS[^\n]*',log).group(0)}
dump(run / 'summary.json', {'status':'PASS','scope':'F1 only; no AHB scheduling / real core integration', 'tests':results})
print('F1_PASS',run / 'summary.json')
