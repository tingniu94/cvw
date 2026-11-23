"""繪製真實EBU FST匯出的Arbitration波形,非理想化時序或GUI截圖。"""
import ctypes as C
import ctypes.util
import json
import sys
from pathlib import Path

OUT=Path(sys.argv[1]).resolve();src=OUT/'ebu/ebu-gate-export.vcd'
prefix='ebu_gate_tb.replicas[0].original_ebu.'
paths={'HCLK':'ebu_gate_tb.HCLK','arb_state':prefix+'ebufsmarb.CurrState',
 'IFUReq':prefix+'IFUReq','LSUReq':prefix+'LSUReq','IFUSave':prefix+'IFUSave',
 'IFURestore':prefix+'IFURestore','IFUDisable':prefix+'IFUDisable','LSUDisable':prefix+'LSUDisable',
 'IFUSelect':prefix+'IFUSelect','LSUSelect':prefix+'LSUSelect',
 'Guard_HREADY':'ebu_gate_tb.ready[0]','IFUHREADY':prefix+'IFUHREADY','LSUHREADY':prefix+'LSUHREADY',
 'IFUHADDR(live)':prefix+'IFUHADDR','IFUHADDROut(saved)':prefix+'IFUHADDROut','EBU_HADDR':prefix+'HADDR',
 'M_HTRANS':'ebu_gate_tb.M_HTRANS','M_HREADY':'ebu_gate_tb.M_HREADY',
 'down_accept':'ebu_gate_tb.down_accept','down_complete':'ebu_gate_tb.down_complete',
 'M_HWDATA':'ebu_gate_tb.M_HWDATA','EBU_HWDATA':prefix+'HWDATA'}
names=list(paths);reverse={v:k for k,v in paths.items()};widths={};codes={};scope=[];signals={n:[] for n in names};time=0;header=True
for line in src.read_text().splitlines():
 p=line.split()
 if not p:continue
 if p[0]=='$scope':scope.append(p[2])
 elif p[0]=='$upscope':scope.pop()
 elif p[0]=='$var':
  full='.'.join(scope+[p[4]])
  if full in reverse:codes.setdefault(p[3],[]).append(reverse[full]);widths[reverse[full]]=int(p[2])
 elif p[0]=='$enddefinitions':header=False
 elif not header:
  if line[0]=='#':time=int(line[1:])
  elif line[0] in 'bB':
   value,code=line[1:].split()
   for n in codes.get(code,[]):signals[n].append((time,value))
  elif line[0] in '01xz':
   for n in codes.get(line[1:],[]):signals[n].append((time,line[0]))
assert len(widths)==len(names),set(names)-set(widths)
lib=C.CDLL(ctypes.util.find_library('cairo'))
def api(name,args,ret=None):
    f=getattr(lib,'cairo_'+name);f.argtypes=args;f.restype=ret;return f
ptr=C.c_void_p;d=C.c_double;i=C.c_int
surface_create=api('image_surface_create',[i,i,i],ptr);create=api('create',[ptr],ptr)
color=api('set_source_rgb',[ptr,d,d,d]);paint=api('paint',[ptr]);move=api('move_to',[ptr,d,d]);line=api('line_to',[ptr,d,d]);stroke=api('stroke',[ptr]);lw=api('set_line_width',[ptr,d]);font=api('set_font_size',[ptr,d]);text=api('show_text',[ptr,C.c_char_p]);rect=api('rectangle',[ptr,d,d,d,d]);fill=api('fill',[ptr]);png=api('surface_write_to_png',[ptr,C.c_char_p],i);destroy=api('destroy',[ptr]);destroy_surface=api('surface_destroy',[ptr])
def render(name,start,end,markers,title):
    W=1900;left=260;right=1850;top=125;rowheight=40;H=top+len(names)*rowheight+100
    surf=surface_create(0,W,H);ctx=create(surf);color(ctx,1,1,1);paint(ctx)
    def label(x,y,s,size=15,rgb=(0.08,0.12,0.18)):
        color(ctx,*rgb);font(ctx,size);move(ctx,x,y);text(ctx,s.encode())
    def segment(x1,y1,x2,y2,rgb=(0.05,0.4,0.62),weight=1.5):
        color(ctx,*rgb);lw(ctx,weight);move(ctx,x1,y1);line(ctx,x2,y2);stroke(ctx)
    def x(t):return left+(t-start)/(end-start)*(right-left)
    label(35,35,title,23)
    label(35,63,'Source: original CV-Wally EBU / FSM arbitration + Guard FST -> fst2vcd; actual signal changes, 1ps timescale.',17)
    label(35,88,'Vertical markers denote sampled rising edges. Values immediately before the edge determine events.',16)
    for t in range((start//10)*10,end+1,10):
        if t<start:continue
        segment(x(t),top-10,x(t),top+len(names)*rowheight-5,(0.89,0.91,0.93),1)
        label(x(t)-8,H-75,str(t),12)
    for n,sig in enumerate(names):
        y=top+n*rowheight
        label(20,y+22,sig,17)
        before=[(t,v) for t,v in signals[sig] if t<=start]
        pts=[(start,before[-1][1] if before else '0')]+[(t,v) for t,v in signals[sig] if start<t<end]
        pts.append((end,pts[-1][1]))
        last_y=None
        for (a,v),(b,_) in zip(pts,pts[1:]):
            if widths[sig]==1:
                yy=y+(3 if v=='1' else 30)
                segment(x(a),yy,x(b),yy)
                if last_y is not None:segment(x(a),last_y,x(a),yy)
                last_y=yy
            else:
                segment(x(a),y+3,x(b),y+3);segment(x(a),y+30,x(b),y+30)
                segment(x(a),y+3,x(a)+3,y+16);segment(x(a)+3,y+16,x(a),y+30)
                try:val=int(v,2);value=f'{val:x}' if widths[sig]>8 else str(val)
                except ValueError:value=v
                if len(value)>12:value=value[:5]+'..'+value[-5:]
                if sig=='arb_state':value={0:'IDLE',1:'ARBITRATE'}.get(val,value)
                if sig=='M_HTRANS':value={0:'IDLE',1:'BUSY',2:'NONSEQ',3:'SEQ'}.get(val,value)
                if x(b)-x(a)>24:label(x(a)+5,y+22,value,14)
    for t in markers:
        segment(x(t),top-10,x(t),top+len(names)*rowheight-5,(0.8,0.22,0.12),2)
        label(x(t)+4,top-15,str(t)+'ps',14,(0.8,0.22,0.12))
    label(left,H-35,'time (ps) - Original controller signals; pre-edge events / post-edge register updates.',17)
    assert png(surf,str(OUT/name).encode())==0
    destroy(ctx);destroy_surface(surf)
windows=json.loads((OUT/'ebu/save-restore-ledger.json').read_text());w=windows[0]
start=w['save_time_ps'];end=w['saved_address_forwarded_time_ps']
render('arbitration-save.png',start-15,start+115,[start],
 'Simultaneous requests: LSU wins; original EBU saves IFU address and disables IFU progress')
render('arbitration-restore.png',end-55,end+85,[end-20,end],
 'Original EBU restores IFU: old LSU response / saved IFU address handoff')
last=next(x for x in windows if x['side']==0 and x['save_time_ps']>7400)
render('arbitration-write-to-ifu.png',last['saved_address_forwarded_time_ps']-55,
 last['saved_address_forwarded_time_ps']+85,
 [last['saved_address_forwarded_time_ps']-20,last['saved_address_forwarded_time_ps']],
 'Write data remains owned by LSU while the next address selects saved IFU request')
lines=['[*] EBU Gate; actual FST paths; header-validated','[dumpfile] "'+str(OUT/'ebu/ebu-gate.fst')+'"','[timestart] '+str(start-30),'[size] 1800 1100']
for n,path in paths.items():
 width=widths[n];lines+=['@28' if width==1 else '@22',path+(f'[{width-1}:0]' if width>1 else '')]
with (OUT/'ebu-gate.gtkw').open('x') as f:f.write('\n'.join(lines)+'\n')
with (OUT/'waveform-render-manifest.json').open('x') as f:json.dump({'source_fst':str(OUT/'ebu/ebu-gate.fst'),
 'source_vcd':str(src),'format':'Actual FST-derived PNG; not GTKWave GUI screenshot',
 'save_marker_ps':start,'restore_markers_ps':[end-20,end],'write_handoff_ps':last['saved_address_forwarded_time_ps']},f,indent=2)
print('Rendered three actual EBU arbitration PNGs and validated GTKWave config')
