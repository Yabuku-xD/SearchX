#!/usr/bin/env python3
"""Repeatable native-browser rendering workload; never uses an ordinary profile."""
import argparse
import json
import os
import plistlib
import runpy
import statistics
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = runpy.run_path(str(ROOT / 'Tests/chrome_support.py'))
HTML = '''<!doctype html><meta charset="utf-8"><title>Motion laboratory</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#f4f4f0;color:#252720;font:16px system-ui}
header{padding:48px 56px 28px}h1{font-size:40px;letter-spacing:-1px;margin:12px 0}
.eyebrow{font-size:12px;letter-spacing:2px;text-transform:uppercase;color:#686d63}
.grid{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:12px;padding:0 56px 40px}
.tile{height:150px;border-radius:16px;overflow:hidden;background:#dde7d9;position:relative}
.orb{position:absolute;inset:20%;border-radius:30%;background:#688761;animation:orbit 2.5s ease-in-out infinite alternate}
.tile:nth-child(3n){background:#e7dfd5}.tile:nth-child(3n) .orb{background:#b09275;animation-delay:-.8s}
.tile:nth-child(3n+1) .orb{animation-delay:-1.7s}
@keyframes orbit{to{transform:translate(22%,15%) rotate(150deg) scale(.65);opacity:.6}}
canvas{position:fixed;right:36px;bottom:24px;width:240px;height:120px;background:#ffffffd9;border-radius:16px}
.paused *{animation-play-state:paused}article{padding:20px 56px;border-top:1px solid #d8dcd5;max-width:100%}
article h2{font-size:22px}article p{max-width:70ch;line-height:1.6}
@media(max-width:700px){header,article{padding-left:24px;padding-right:24px}.grid{padding:0 24px 24px;grid-template-columns:repeat(3,minmax(0,1fr))}}
</style><header><div class="eyebrow">Search · rendering study</div><h1>Motion, with room to breathe.</h1>
<p id="identity"></p><p>A repeatable canvas, composited animation and long-page scrolling workload.</p></header>
<div class="grid"></div><main></main><canvas width="480" height="240"></canvas>
<script>
document.querySelector('#identity').textContent=location.pathname;
document.querySelector('.grid').innerHTML=Array.from({length:36},()=>'<div class="tile"><div class="orb"></div></div>').join('');
document.querySelector('main').innerHTML=Array.from({length:120},(_,i)=>'<article><h2>Section '+(i+1)+'</h2><p>Clear hierarchy and deliberate spacing keep this long document readable. Native scrolling should track the gesture while animated content keeps moving.</p></article>').join('');
const ctx=document.querySelector('canvas').getContext('2d');
window.startMeasure=(mode,duration)=>{
 document.body.classList.toggle('paused',mode==='idle'); window.scrollTo(0,0);
 const out=window.measurement={mode,duration,done:false,intervals:[],scrollStart:scrollY};
 let start,last;const ceiling=document.documentElement.scrollHeight-innerHeight;
 function frame(t){
  if(start===undefined){start=t;last=t}else{out.intervals.push(t-last);last=t}
  const elapsed=t-start;
  if(mode!=='idle'){
   ctx.clearRect(0,0,480,240);
   for(let i=0;i<400;i++){const a=i*.618+t*.0004;ctx.fillStyle=i%2?'#6e8866':'#ba9776';
    ctx.fillRect(240+Math.sin(a)*220,120+Math.cos(a*1.31)*100,3,3)}
  }
  if(mode==='scroll')window.scrollTo(0,Math.min(ceiling,elapsed*.6));
  if(elapsed<duration)requestAnimationFrame(frame);else{out.done=true;out.elapsed=elapsed;out.scrollEnd=scrollY;out.hidden=document.hidden}
 }requestAnimationFrame(frame);return true;
};
</script>'''


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        body = HTML.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def process_sample(pid, web_pids):
    text = subprocess.check_output(['ps', '-p', ','.join(map(str,[pid,*web_pids])),
                                    '-o', 'pid=', '-o', 'rss=', '-o', 'time='], text=True)
    rows={}
    for line in text.strip().splitlines():
        process, rss, cpu = line.split()
        parts = cpu.split(':')
        seconds = float(parts[-1]) + int(parts[-2]) * 60
        if len(parts) == 3:
            seconds += int(parts[0]) * 3600
        rows[int(process)]={'rss':int(rss),'cpu':seconds}
    return {'time': time.monotonic(), 'appRSSKiB': rows[pid]['rss'], 'appCPUSeconds': rows[pid]['cpu'],
            'contentRSSKiB':sum(r['rss'] for p,r in rows.items() if p!=pid),
            'contentCPUSeconds':sum(r['cpu'] for p,r in rows.items() if p!=pid)}


def summary(intervals):
    values = sorted(intervals)
    def percentile(p):
        return values[round((len(values)-1)*p)]
    return {'frames': len(values), 'fps': 1000/statistics.mean(values),
            'p50ms': percentile(.5), 'p95ms': percentile(.95), 'p99ms': percentile(.99),
            'over12_5msPercent': 100*sum(v>12.5 for v in values)/len(values),
            'over25msPercent': 100*sum(v>25 for v in values)/len(values)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True, help='Explicit immutable baseline or optimized current probe binary')
    parser.add_argument('--label', required=True)
    parser.add_argument('--seconds', type=float, default=8)
    parser.add_argument('--repeat', type=int, default=3)
    parser.add_argument('--transparency', type=float, default=0)
    parser.add_argument('--ui-only', action='store_true')
    parser.add_argument('--composited', action='store_true', help='Also capture the owned window through ScreenCaptureKit')
    parser.add_argument('--tabs', type=int, default=0)
    parser.add_argument('--rate', choices=['fast','default','mixed'], default='fast')
    parser.add_argument('--particles', type=int, default=400)
    parser.add_argument('--wheel', action='store_true')
    args = parser.parse_args()
    global HTML
    HTML = HTML.replace('i<400',f'i<{args.particles}')
    args.world = 'perf-' + uuid.uuid4().hex[:10]
    os.environ['SEARCH_MEASURE'] = '1'
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    run = SUPPORT['Run'](args, f'http://127.0.0.1:{server.server_port}')
    artifact = ROOT / '.local-performance' / (args.label + '-' + args.world)
    artifact.mkdir(parents=True)
    run.report.update(label=args.label, command='python3 Tests/performance.py ' + ' '.join(
        '--'+key.replace('_','-')+((' '+str(value)) if not isinstance(value,bool) else '')
        for key,value in vars(args).items() if key!='world' and value is not False),
        artifact=str(artifact), samples=[], os=subprocess.check_output(['sw_vers'], text=True),
        memoryScope='App and owned WebKit content RSS reported separately; excludes GPU/network and shared-page accounting',
        measurement='requestAnimationFrame intervals, not display-present timestamps; measured page ignores automation-window occlusion')
    (artifact/'fixture.html').write_text(HTML)

    def shot(name):
        run.ask('native', action='shot', path=str(artifact / (name + '.png')))
        if not args.composited or 'captureError' in run.report:
            return
        path = artifact / (name + '-composited.png')
        try:
            run.ask('native', action='composited-shot', path=str(path))
            status = Path(str(path) + '.json')
            deadline = time.monotonic() + 10
            while not status.exists() and time.monotonic() < deadline:
                time.sleep(.1)
            result = json.loads(status.read_text()) if status.exists() else {'error': 'capture timed out'}
            if 'error' in result:
                run.report['captureError'] = result['error']
        except RuntimeError as error:
            run.report['captureError'] = str(error)

    try:
        run.prepare()
        (run.profile/'session.json').unlink()
        prefs = plistlib.loads((run.directory/'prefs.plist').read_bytes())
        prefs.update({'chrome.transparency': args.transparency, 'tabs.pictures': args.tabs>0})
        (run.directory/'prefs.plist').write_bytes(plistlib.dumps(prefs))
        subprocess.run(['defaults','import',run.suite,str(run.directory/'prefs.plist')],check=True)
        run.launch()
        run.ask('native',action='performance',front=True)
        run.ask('resize',width=1280,height=900,steps=1)
        run.ask('ui',sidebar=True,side='left',look='light',pages120=args.rate=='fast')
        tab = run.open('/rendering')
        states={'fast':['new120'],'default':['default60'],'mixed':['default60','live120','reload120','new120']}[args.rate]
        for state in ([] if args.ui_only else states):
            if state == 'live120':
                run.ask('ui',pages120=True)
            if state == 'reload120':
                run.js(tab, 'location.reload()')
                run.page(tab, '/rendering')
            if state == 'new120' and args.rate=='mixed':
                tab = run.open('/rendering-fast')
            run.ask('native',action='performance',render=True)
            run.report[state+'Probe'] = run.ask('probe')
            for mode in (['animation'] if state in ('live120','reload120') else (['wheel'] if args.wheel else ['idle','animation','scroll'])):
                for iteration in range(args.repeat):
                    probe=run.ask('probe')
                    row=next(r for r in probe['rows'] if r['key'])
                    frame=next(w['frame'] for w in probe['windows'] if w['number']==row['host'])
                    run.ask('native',action='click',x=frame[0]+frame[2]-80,y=frame[1]+80)
                    run.js(tab, "startMeasure('animation',750)")
                    warm_deadline=time.monotonic()+10
                    while not run.js(tab,'window.measurement.done') and time.monotonic()<warm_deadline:
                        time.sleep(.1)
                    diagnostics=run.ask('native',action='performance',reset=True)
                    before=process_sample(run.process.pid,diagnostics['webPIDs'])
                    run.js(tab,f'startMeasure({json.dumps(mode)},{args.seconds*1000})')
                    wheel=[]
                    if mode=='wheel':
                        def scroll():
                            wheel.append(run.ask('pull',dx=0.0,dy=args.seconds*600,steps=round(args.seconds*120),ms=args.seconds*1000))
                        thread=threading.Thread(target=scroll)
                        thread.start()
                    samples=[before]
                    deadline=time.monotonic()+args.seconds+20
                    while time.monotonic()<deadline:
                        time.sleep(.5)
                        samples.append(process_sample(run.process.pid,diagnostics['webPIDs']))
                        visible=run.js(tab,'({hidden:document.hidden,focus:document.hasFocus()})')
                        if visible['hidden']:
                            (artifact/'visibility-failure.json').write_text(json.dumps({
                                'page':visible,'native':run.ask('native',action='performance'),
                                'probe':run.ask('probe')},indent=2))
                        if run.js(tab,'window.measurement.done'):
                            break
                    result=run.js(tab,'window.measurement')
                    (artifact/'latest-workload.json').write_text(json.dumps(result,indent=2))
                    run.check(result['done'] and not result['hidden'], state+' '+mode+' completed visibly')
                    if mode in ('scroll','wheel'):
                        run.check(result['scrollEnd']>1000,'long page actually scrolled')
                    if mode=='wheel':
                        thread.join(timeout=5)
                        run.check(bool(wheel) and wheel[0]['before']==wheel[0]['after'],'vertical gesture preserves navigation')
                    native=run.ask('native',action='performance')
                    after=samples[-1]
                    result.update(state=state,iteration=iteration,process=samples,scrollMessages=native['scrollMessages'],native=native,
                        summary=summary(result['intervals']),
                        appCPUPercent=100*(after['appCPUSeconds']-before['appCPUSeconds'])/(after['time']-before['time']),
                        contentCPUPercent=100*(after['contentCPUSeconds']-before['contentCPUSeconds'])/(after['time']-before['time']),
                        appRSSPeakMiB=max(s['appRSSKiB'] for s in samples)/1024,
                        contentRSSPeakMiB=max(s['contentRSSKiB'] for s in samples)/1024)
                    run.report['samples'].append(result)
                    (artifact/'result.json').write_text(json.dumps(run.report,indent=2))
                    print(json.dumps({k:result[k] for k in ['state','mode','summary','scrollMessages','appCPUPercent','appRSSPeakMiB']}),flush=True)
        run.js(tab,'window.scrollTo(0,0)')
        for side,look,width,height in [('left','light',1280,900),('right','dark',1280,900),('left','light',760,560)]:
            run.ask('ui',side=side,look=look)
            run.ask('resize',width=width,height=height,steps=1)
            name=f'{side}-{look}-{width}'
            shot(name)
            (artifact/(name+'-nodes.json')).write_text(json.dumps(run.ask('native',action='nodes'),indent=2))
            (artifact/(name+'-native.json')).write_text(json.dumps(run.ask('native',action='performance'),indent=2))
        if args.tabs:
            run.ask('resize',width=1280,height=900,steps=1)
            for i in range(args.tabs-1):
                tab=run.open('/tab-'+str(i))
            run.ask('native',action='performance',front=True,render=True,reset=True)
            start=time.monotonic()
            run.ask('press',code=48,chars='\t',mods=['ctrl'])
            run.report['switcher']={'tabs':len(run.ask('tabs')['tabs']),
                'secondsToProbe':time.monotonic()-start,**run.ask('native',action='performance')}
            shot('switcher')
            run.ask('press',code=53,chars='\u001b',mods=[])
            run.check(len(run.ask('tabs')['tabs'])==args.tabs,'switcher preserves every tab')
        if args.ui_only:
            run.ask('resize',width=640,height=420,steps=1)
            for panel in ['settings','history','downloads','bookmarks']:
                run.ask('ui',**{panel:True})
                title='General' if panel=='settings' else panel.capitalize()
                deadline=time.monotonic()+10
                previous=None
                stable=time.monotonic()
                while time.monotonic()<deadline:
                    rows=run.ask('native',action='nodes')['nodes']
                    positions=[n['frame'] for n in rows if title in (n['value'],n['title'],n['label'])]
                    if positions!=previous:
                        previous,stable=positions,time.monotonic()
                    if positions and time.monotonic()-stable>.25:
                        break
                    time.sleep(.1)
                run.check(bool(positions),'panel is drawn: '+panel)
                shot(panel+'-640')
                (artifact/(panel+'-640-nodes.json')).write_text(json.dumps(run.ask('native',action='nodes'),indent=2))
                run.ask('ui',**{panel:False})
            run.ask('press',code=37,chars='l',mods=['cmd'])
            shot('address-640')
            (artifact/'address-640-nodes.json').write_text(json.dumps(run.ask('native',action='nodes'),indent=2))
            run.ask('press',code=53,chars='\u001b',mods=[])
        run.report['passed']=True
    except Exception as error:
        run.report.update(passed=False,error=str(error))
        raise
    finally:
        (artifact/'result.json').write_text(json.dumps(run.report,indent=2))
        run.stop()
        server.shutdown()
        print('Artifact:',artifact,flush=True)


if __name__=='__main__':
    main()
