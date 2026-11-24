"""Render actual fst2vcd-exported signal changes; not a GUI screenshot or simulation."""
import ctypes as C
import ctypes.util
import json
import sys
from pathlib import Path

OUT=Path(sys.argv[1]).resolve()
src=OUT/'dcache/controller-gate-export.vcd'
names=['HCLK','M_HREADY','M_HTRANS','M_HADDR','M_HWRITE','M_HWDATA','M_HWSTRB','wd[0]','beat[0]','ready[0]','down_accept','down_complete','ack[0]','ack[1]','fetch[0]']
widths={};codes={};scope=[];signals={n:[] for n in names};time=0;header=True
for line in src.read_text().splitlines():
    p=line.split()
    if not p:continue
    if p[0]=='$scope':scope.append(p[2])
    elif p[0]=='$upscope':scope.pop()
    elif p[0]=='$var' and scope==['controller_gate_tb'] and p[4] in names:
        codes[p[3]]=p[4];widths[p[4]]=int(p[2])
    elif p[0]=='$enddefinitions':header=False
    elif not header:
        if line[0]=='#':time=int(line[1:])
        elif line[0] in 'bB':
            value,code=line[1:].split()
            if code in codes:signals[codes[code]].append((time,value))
        elif line[0] in '01xXzZ' and line[1:] in codes:
            signals[codes[line[1:]]].append((time,line[0]))
assert len(codes)==len(names),codes
# Display final FetchBuffer word, derived solely from actual 512-bit trace.
changes=signals.pop('fetch[0]');widths.pop('fetch[0]');names[-1]='FetchBuffer[511:448]'
signals[names[-1]]=[(t,bin(int(v,2)>>448)[2:]) for t,v in changes];widths[names[-1]]=64
lib=C.CDLL(ctypes.util.find_library('cairo'))
def api(name,args,ret=None):
    f=getattr(lib,'cairo_'+name);f.argtypes=args;f.restype=ret;return f
ptr=C.c_void_p;d=C.c_double;i=C.c_int
surface_create=api('image_surface_create',[i,i,i],ptr);create=api('create',[ptr],ptr)
color=api('set_source_rgb',[ptr,d,d,d]);paint=api('paint',[ptr]);move=api('move_to',[ptr,d,d]);line=api('line_to',[ptr,d,d]);stroke=api('stroke',[ptr]);lw=api('set_line_width',[ptr,d]);font=api('set_font_size',[ptr,d]);text=api('show_text',[ptr,C.c_char_p]);rect=api('rectangle',[ptr,d,d,d,d]);fill=api('fill',[ptr]);png=api('surface_write_to_png',[ptr,C.c_char_p],i);destroy=api('destroy',[ptr]);destroy_surface=api('surface_destroy',[ptr])
def render(name,start,end,markers,title):
    W=1800;left=270;right=1750;top=125;rowheight=48;H=top+len(names)*rowheight+100
    surf=surface_create(0,W,H);ctx=create(surf);color(ctx,1,1,1);paint(ctx)
    def label(x,y,s,size=15,rgb=(0.08,0.12,0.18)):
        color(ctx,*rgb);font(ctx,size);move(ctx,x,y);text(ctx,s.encode())
    def segment(x1,y1,x2,y2,rgb=(0.05,0.4,0.62),weight=1.5):
        color(ctx,*rgb);lw(ctx,weight);move(ctx,x1,y1);line(ctx,x2,y2);stroke(ctx)
    def x(t):return left+(t-start)/(end-start)*(right-left)
    label(35,35,title,23)
    label(35,63,'Source: original CV-Wally controller + Guard FST -> fst2vcd; actual signal changes, 1ps timescale.',17)
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
        for idx in range(len(pts)-1):
            (a,v),(b,_) = pts[idx],pts[idx+1]
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
                if sig=='M_HTRANS':value={0:'IDLE',1:'BUSY',2:'NONSEQ',3:'SEQ'}.get(val,value)
                if x(b)-x(a)>24:label(x(a)+5,y+22,value,14)
    for t in markers:
        segment(x(t),top-10,x(t),top+len(names)*rowheight-5,(0.8,0.22,0.12),2)
        label(x(t)+4,top-15,str(t)+'ps',14,(0.8,0.22,0.12))
    label(left,H-35,'time (ps) - Original controller signals; pre-edge events / post-edge register updates.',17)
    assert png(surf,str(OUT/name).encode())==0
    destroy(ctx);destroy_surface(surf)
ledger=json.loads((OUT/'dcache/beat-ledger.json').read_text())
acks=json.loads((OUT/'dcache/ack-fetch-ledger.json').read_text())
first_write=next(o for o in ledger if o['request']['write'] and o['request']['burst']==5)
t0=first_write['request']['up_accept_cycle']*10+5
render('writeback-address-data.png',t0-15,t0+145,
 [t0,first_write['accept_cycle']*10+5,first_write['data_complete_cycle']*10+5],
 'Original writeback: address N+1 / saved data N / accepted data N')
last_write=[o for o in ledger if o.get('burst_id')==3][-1]
t1=last_write['accept_cycle']*10+5;t2=last_write['a_complete_cycle']*10+5
render('writeback-last-data-ack.png',t1-35,t2+25,
 [t1,last_write['data_complete_cycle']*10+5,t2],
 'Stalled writeback: final address accepted, then final data completes, then CacheBusAck')
last_read=[o for o in ledger if o.get('burst_id')==0][-1]
t3=last_read['accept_cycle']*10+5;t4=last_read['a_complete_cycle']*10+5
render('refill-fetch-buffer-ack.png',t3-35,t4+25,
 [t3,last_read['data_complete_cycle']*10+5,t4],
 'Read refill: final Data Completion precedes Ack / final FetchBuffer register update')
# GTKWave settings validated against actual VCD top-level names.
gtkw=['[*] Controller Gate; original RTL; 1ps; header-validated',
       '[dumpfile] "'+str(OUT/'dcache/controller-gate.fst')+'"','[timestart] 0','[size] 1700 1000']
for n in ['HCLK','HRESETn','ready[0]','ready[1]','addr[0]','addr[1]','wd[0]','wd[1]',
          'strb[0]','strb[1]','beat[0]','beat[1]','ack[0]','ack[1]','fetch[0]','fetch[1]',
          'M_HTRANS','M_HBURST','M_HADDR','M_HWRITE','M_HWDATA','M_HWSTRB','M_HREADY',
          'M_HRDATA','down_accept','down_complete','pair_valid','match_valid','authorized_dispatch']:
 # Widths absent from selected rendering dictionary are known from parsed VCD header.
 import re
 header=src.read_text().split('$enddefinitions')[0]
 m=re.search(r'\$var \S+ (\d+) \S+ '+re.escape(n)+r'(?: |\[)',header)
 assert m,n
 w=int(m.group(1));gtkw+=['@28' if w==1 else '@22','controller_gate_tb.'+n+(f'[{w-1}:0]' if w>1 else '')]
with (OUT/'controller-gate.gtkw').open('x') as f:f.write('\n'.join(gtkw)+'\n')
with (OUT/'waveform-render-manifest.json').open('x') as f:json.dump({
 'source_fst':str(OUT/'dcache/controller-gate.fst'),'source_vcd':str(src),
 'format':'Actual FST-derived PNG, not GTKWave GUI screenshot',
 'write_first_markers_ps':[t0,first_write['accept_cycle']*10+5,first_write['data_complete_cycle']*10+5],
 'write_last_markers_ps':[t1,last_write['data_complete_cycle']*10+5,t2],
 'read_last_markers_ps':[t3,last_read['data_complete_cycle']*10+5,t4]},f,indent=2)
print('Rendered three actual Controller FST waveform PNGs; GTKWave config validated')
