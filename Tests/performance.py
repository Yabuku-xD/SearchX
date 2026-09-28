#!/usr/bin/env python3
"""Repeatable native-browser rendering workload; never uses an ordinary profile."""
import argparse
import hashlib
import json
import os
import plistlib
import runpy
import shlex
import statistics
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

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


def summary(intervals, target_hz):
    values = sorted(intervals)
    if not values:
        return {'frames': 0, 'targetHz': target_hz}
    def percentile(p):
        return values[round((len(values)-1)*p)]
    result = {'frames': len(values), 'fps': 1000/statistics.mean(values), 'targetHz': target_hz,
            'p50ms': percentile(.5), 'p95ms': percentile(.95), 'p99ms': percentile(.99),
            'over12_5msPercent': 100*sum(v>12.5 for v in values)/len(values),
            'over25msPercent': 100*sum(v>25 for v in values)/len(values)}
    if target_hz:
        budget = 1000 / target_hz
        result.update(latePercent=100*sum(v>budget*1.5 for v in values)/len(values),
                      missedFramePeriods=sum(max(0, round(v/budget)-1) for v in values))
    return result


def run_feed(args):
    """Long native-wheel run with real filter installation and local media/API I/O."""
    video_path = Path(args.video).resolve()
    video = video_path.read_bytes()
    fixture = (ROOT/'Tests/feed.html').read_bytes()
    batch_size, response_delay = 25, .080

    class FeedFixture(BaseHTTPRequestHandler):
        def do_GET(self):
            url = urlparse(self.path)
            headers = {'Cache-Control': 'no-store'}
            status = 200
            if url.path == '/video.mp4':
                start, end = 0, len(video)-1
                if self.headers.get('Range', '').startswith('bytes='):
                    bounds = self.headers['Range'][6:].split('-')
                    start = int(bounds[0] or 0)
                    end = min(int(bounds[1]) if bounds[1] else end, end)
                    status = 206
                    headers['Content-Range'] = f'bytes {start}-{end}/{len(video)}'
                body, kind = video[start:end+1], 'video/mp4'
                headers['Accept-Ranges'] = 'bytes'
            elif url.path == '/feed-batch':
                cursor = int(parse_qs(url.query)['cursor'][0])
                time.sleep(response_delay)
                body = json.dumps({'items': list(range(cursor, cursor+batch_size))}).encode()
                kind = 'application/json'
            else:
                body, kind = fixture, 'text/html; charset=utf-8'
            self.send_response(status)
            for key, value in headers.items(): self.send_header(key, value)
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            try: self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError): pass

        def log_message(self, *_): pass

    args.world = 'feed-' + uuid.uuid4().hex[:10]
    if args.test_scheduling:
        os.environ.pop('SEARCH_MEASURE', None)
    else:
        os.environ['SEARCH_MEASURE'] = '1'
    server = ThreadingHTTPServer(('127.0.0.1', 0), FeedFixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    run = SUPPORT['Run'](args, f'http://127.0.0.1:{server.server_port}')
    artifact = ROOT/'.local-performance'/(args.label+'-'+args.world)
    artifact.mkdir(parents=True)
    (artifact/'fixture.html').write_bytes(fixture)
    filters = '''127.0.0.1##.feed-card:has-text(Sponsored)
127.0.0.1##.feed-card:has-text(CommercialA)
127.0.0.1##.feed-card:has-text(CommercialB)
127.0.0.1##+js(remove-attr, data-tracking, .feed-helper, stay)
127.0.0.1##+js(remove-class, advert, .feed-helper, stay)
127.0.0.1##+js(set-attr, .feed-helper, data-clean, true)
'''
    instrument = r'''(()=>{
      window.feedCosts={queries:0,candidates:0,queryMs:0,chunks:0,chunkMs:0,maxChunkMs:0};
      const original=Document.prototype.querySelectorAll;
      Document.prototype.querySelectorAll=function(selector){
        const start=performance.now(),result=original.call(this,selector);
        if(selector==='.feed-card'||selector==='.feed-helper'){
          feedCosts.queries++;feedCosts.candidates+=result.length;feedCosts.queryMs+=performance.now()-start;
        }return result;
      };
      const raf=requestAnimationFrame;
      window.requestAnimationFrame=function(fn){return raf.call(window,function(t){
        const start=performance.now();try{return fn(t)}finally{
          if(fn.name==='chunk'||fn.name==='persistentChunk'){
            const ms=performance.now()-start;feedCosts.chunks++;feedCosts.chunkMs+=ms;feedCosts.maxChunkMs=Math.max(feedCosts.maxChunkMs,ms);
          }
        }
      })};return true;
    })()'''
    run.report.update(mode=args.feed, duration=args.seconds, initialCards=args.feed_cards,
        targetHz=120 if args.rate=='fast' else 60, resources=[], browserWork=[],
        video=str(video_path), videoSHA256=hashlib.sha256(video).hexdigest(),
        fixtureResponseDelayMs=response_delay*1000, fixtureBatchSize=batch_size,
        scheduling='test activity and inactive-page overrides' if args.test_scheduling else 'shipping background policies',
        command=' '.join(shlex.quote(part) for part in ['python3',*sys.argv]),
        measurement='Headless animation/video callbacks, not physical display presentation; CPU/RSS excludes GPU/network.')
    try:
        run.prepare()
        (run.profile/'session.json').unlink()
        (run.profile/'filters').mkdir()
        (run.profile/'filters/mine.txt').write_text(filters)
        (artifact/'filters.txt').write_text(filters)
        run.launch()
        run.ask('ui', sidebar=False, pages120=args.rate=='fast')
        run.ask('resize', width=1280, height=900, steps=1)
        tab = run.open('/feed')
        run.ask('native', action='performance', render=True)
        run.js(tab, f'setupFeed({json.dumps(args.feed)},{args.feed_cards})')
        until = time.monotonic()+20
        ready = False
        while time.monotonic()<until:
            ready = run.js(tab, "movie.readyState>=3 && !movie.paused && movie.currentTime>0 && getComputedStyle(feed.firstElementChild).display==='none' && feed.lastElementChild.dataset.clean==='true'")
            if ready: break
            time.sleep(.1)
        run.check(ready, 'video plays and installed filters/helpers have applied')
        run.js(tab, 'scrollTo(0,document.documentElement.scrollHeight-innerHeight-2400);true')
        time.sleep(.5)
        run.js(tab, instrument)
        run.ask('eval', id=tab, world='search', js=instrument)
        native = run.ask('native', action='performance', reset=True)
        run.report['resources'].append(process_sample(run.process.pid, native['webPIDs']))
        run.js(tab, f'startFeed({args.seconds*1000})')
        before_url = next(t['url'] for t in run.ask('tabs')['tabs'] if t['id']==tab)
        # The wheel command returns immediately. A long pull waits until its
        # gesture ends, exceeding the automation interface's reply deadline.
        wheel = run.ask('wheel', pixels=-15.0, count=round(args.seconds*120), ms=1000/120)
        deadline = time.monotonic()+args.seconds+20
        while time.monotonic()<deadline:
            time.sleep(1)
            run.report['resources'].append(process_sample(run.process.pid, native['webPIDs']))
            costs = {'time': time.monotonic(), 'page': run.js(tab, 'feedCosts'),
                     'filters': run.ask('eval', id=tab, world='search', js='feedCosts').get('value')}
            run.report['browserWork'].append(costs)
            if run.js(tab, 'feedMeasure.done'): break
        result = run.js(tab, 'feedMeasure')
        run.report['feed'] = result
        after_url = next(t['url'] for t in run.ask('tabs')['tabs'] if t['id']==tab)
        run.report['scroll'] = {'before': before_url, 'after': after_url, **wheel}
        target = run.report['targetHz']
        run.report['frameTiming'] = summary([pair[1] for pair in result['frames']], target)
        run.report['segments'] = []
        for start in range(0, round(args.seconds*1000), 10000):
            intervals = [delta for at, delta in result['frames'] if start<=at<start+10000]
            run.report['segments'].append({'startMs': start, **summary(intervals, target)})
        before, after = run.report['resources'][0], run.report['resources'][-1]
        run.report['appCPUPercent'] = 100*(after['appCPUSeconds']-before['appCPUSeconds'])/(after['time']-before['time'])
        run.report['contentCPUPercent'] = 100*(after['contentCPUSeconds']-before['contentCPUSeconds'])/(after['time']-before['time'])
        run.check(result['done'] and not result['hidden'], 'long feed completes with document visibility reported as visible')
        run.check(wheel.get('sent')==round(args.seconds*120) and before_url==after_url, 'native scroll preserves navigation')
        run.check(result['scrollEnd']-result['scrollStart']>1000, 'native wheel actually scrolls the feed')
        run.check(len(result['requests'])>=2 and all('error' not in r for r in result['requests']), 'feed loads repeated response batches')
        run.check(result['logicalItems']>result['initialItems'], 'new feed items arrive during scrolling')
        if args.feed=='recycle': run.check(result['retained']==args.feed_cards, 'recycled feed keeps its DOM row count stable')
        else: run.check(result['retained']>args.feed_cards, 'retained feed grows throughout the run')
        run.check(result['after']['inViewport'] and not result['after']['paused'] and not result['after']['error'] and result['after']['time']-result['before']['time']>args.seconds*.8, 'visible video continues through the feed run')
        run.report['passed'] = True
        print(json.dumps({'mode': args.feed, 'timing': run.report['frameTiming'],
                          'items': result['logicalItems'], 'retained': result['retained']}), flush=True)
    except Exception as error:
        run.report.update(passed=False, error=str(error))
        raise
    finally:
        (artifact/'result.json').write_text(json.dumps(run.report, indent=2))
        run.stop()
        server.shutdown()
        print('Artifact:', artifact, flush=True)


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
    parser.add_argument('--feed', choices=['grow','recycle'], help='Long feed, network and visible-video workload')
    parser.add_argument('--feed-cards', type=int, default=200)
    parser.add_argument('--video', help='Local MP4 longer than --seconds, used only by --feed')
    parser.add_argument('--test-scheduling', action='store_true',
                        help='Feed diagnostic: use existing test activity/background overrides to check for headless throttling')
    args = parser.parse_args()
    if args.feed:
        if not args.video or not Path(args.video).is_file(): parser.error('--feed requires --video pointing to a local MP4')
        if args.seconds<20: parser.error(f'--feed needs at least 20 seconds for repeated batches; requested {args.seconds}')
        if args.feed_cards<25: parser.error(f'--feed-cards must fit a 25-post response batch; requested {args.feed_cards}')
        if args.rate=='mixed': parser.error('--feed measures one --rate per run; choose fast or default')
        run_feed(args)
        return
    if args.test_scheduling:
        parser.error('--test-scheduling is a diagnostic for --feed runs')
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
                        summary=summary(result['intervals'],native.get('pageTargetHz')),
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
