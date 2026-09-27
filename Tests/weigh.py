#!/usr/bin/env python3
"""Launch and weigh the release app the way the product page measured it.

Launch: from the launch call to the app's first window on screen (window
server). Memory: physical footprint of the app and every process macOS holds
it responsible for (its WebKit content, networking and GPU processes),
summed. Isolated test worlds (SEARCH_PROBE) with SEARCH_MEASURE, wiped per
run. Medians of three runs after one warm-up.

Run: SEARCH_SIGN_IDENTITY= ./build.sh && python3 Tests/weigh.py
"""
import ctypes, ctypes.util, json, os, shutil, statistics, subprocess, tempfile, time, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'build/SearchX.app'
PAGES = ['https://en.wikipedia.org/wiki/Web_browser', 'https://www.apple.com/',
         'https://github.com/', 'https://www.youtube.com/', 'https://example.com/']

libc = ctypes.CDLL(ctypes.util.find_library('c'))
libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
responsible = libc.responsibility_get_pid_responsible_for_pid
responsible.restype = ctypes.c_int
responsible.argtypes = [ctypes.c_int]

class RusageV4(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in (
        'user_time', 'system_time', 'pkg_idle_wkups', 'interrupt_wkups', 'pageins', 'wired_size',
        'resident_size', 'phys_footprint', 'proc_start_abstime', 'proc_exit_abstime',
        'child_user_time', 'child_system_time', 'child_pkg_idle_wkups', 'child_interrupt_wkups',
        'child_pageins', 'child_elapsed_abstime', 'diskio_bytesread', 'diskio_byteswritten',
        'cpu_time_qos_default', 'cpu_time_qos_maintenance', 'cpu_time_qos_background',
        'cpu_time_qos_utility', 'cpu_time_qos_legacy', 'cpu_time_qos_user_initiated',
        'cpu_time_qos_user_interactive', 'billed_system_time', 'serviced_system_time',
        'logical_writes', 'lifetime_max_phys_footprint', 'instructions', 'cycles',
        'billed_energy', 'serviced_energy', 'interval_max_phys_footprint', 'runnable_time')]

def footprint(pid):
    info = RusageV4()
    return info.phys_footprint if libproc.proc_pid_rusage(pid, 4, ctypes.byref(info)) == 0 else 0

def family(app_pid):
    pids = [int(p) for p in subprocess.check_output(['ps', '-axo', 'pid='], text=True).split()]
    return [p for p in pids if p == app_pid or responsible(p) == app_pid]

WAITER = Path(tempfile.gettempdir()) / 'search-first-window'
subprocess.run(['swiftc', '-O', str(ROOT / 'Tests/first-window.swift'), '-o', str(WAITER)], check=True)

def first_window(pid):
    return subprocess.run([str(WAITER), str(pid)]).returncode == 0

def launched(since):
    """The newest process running this app's binary, started by us."""
    end = time.monotonic() + 10
    while time.monotonic() < end:
        out = subprocess.run(['pgrep', '-n', '-f', str(APP / 'Contents/MacOS/SearchX')], capture_output=True, text=True).stdout.strip()
        if out:
            return int(out)
        time.sleep(0.002)
    raise RuntimeError('app did not start')

def once(urls, settle):
    world = 'weigh-' + uuid.uuid4().hex[:8]
    start = time.monotonic()
    # As a link clicked in another app hands pages over: through Launch
    # Services, a new instance, into a world of its own.
    subprocess.run(['open', '-n', '-a', str(APP), '--env', 'SEARCH_PROBE=' + world,
                    '--env', 'SEARCH_MEASURE=1', *urls], check=True)
    pid = launched(start)
    try:
        if not first_window(pid):
            raise RuntimeError('no window')
        launch = (time.monotonic() - start) * 1000
        time.sleep(settle)
        pids = family(pid)
        memory = sum(footprint(p) for p in pids) / 1e6
        return {'launchMs': round(launch), 'memoryMB': round(memory), 'processes': len(pids)}
    finally:
        os.kill(pid, 15)
        end = time.monotonic() + 20
        while time.monotonic() < end:
            try:
                os.kill(pid, 0)
                time.sleep(.1)
            except ProcessLookupError:
                break
        support = Path.home() / 'Library/Application Support' / f'Search ({world})'
        if support.is_dir():
            shutil.rmtree(support)

def median(rows):
    return {k: statistics.median(r[k] for r in rows) for k in rows[0]}

def main():
    size = int(subprocess.check_output(['du', '-sk', str(APP)], text=True).split()[0]) * 1024
    report = {'app': str(APP), 'onDiskMB': round(size / 1e6, 2)}
    once([], 3)  # macOS's first-launch inspection of a freshly signed build
    report['empty'] = [once([], 5) for _ in range(3)]
    report['fiveTabs'] = [once(PAGES, 25) for _ in range(3)]
    report['emptyMedian'] = median(report['empty'])
    report['fiveTabsMedian'] = median(report['fiveTabs'])
    out = ROOT / ('.local-resolution/evidence/weigh-' + time.strftime('%Y%m%d-%H%M%S') + '.json')
    out.write_text(json.dumps(report, indent=2))
    print(json.dumps({k: report[k] for k in ('onDiskMB', 'emptyMedian', 'fiveTabsMedian')}))
    print('Report:', out)


if __name__ == '__main__':
    main()
