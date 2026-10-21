"""Clean build to first frame: the host's desktop device versus Raccoon.

    python3 first_frame.py <project> [--rounds N] [--devices macos,raccoon] [--warm]

Each run does `flutter clean` (skipped with --warm), then
`flutter run -d <device> --machine`, and times from spawn to the app's
RACCOON_FIRST_FRAME line, which the app prints once its first frame is
rasterized (see wonderous.sh for the probe). Devices alternate so caching and
thermal effects spread evenly. The default devices are the host's desktop
device (linux, macos or windows) and raccoon.
"""
import json
import platform
import subprocess
import sys
import threading
import time

PROBE = 'RACCOON_FIRST_FRAME'


def host_device():
    return {'Darwin': 'macos', 'Windows': 'windows'}.get(platform.system(), 'linux')


def run(project, flutter, device, clean, timeout):
    if clean:
        subprocess.run([flutter, 'clean'], cwd=project, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=True)
    t0 = time.time()
    p = subprocess.Popen([flutter, 'run', '-d', device, '--machine'], cwd=project,
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True, bufsize=1)
    marks, raw, app_id, done = {}, [], [None], threading.Event()

    def reader():
        for line in p.stdout:
            raw.append(line.rstrip())
            s = line.strip()
            # The app's own output arrives as plain lines next to the events.
            if PROBE in s and 'first frame' not in marks:
                marks['first frame'] = time.time() - t0
                done.set()
            if not s.startswith('['):
                continue
            try:
                events = json.loads(s)
            except ValueError:
                continue
            for m in events:
                event, params = m.get('event'), m.get('params', {})
                if event == 'app.start':
                    app_id[0] = params.get('appId')
                if event == 'app.started':
                    marks.setdefault('app.started', time.time() - t0)

    reading = threading.Thread(target=reader, daemon=True)
    reading.start()
    # Stop waiting as soon as flutter run exits, for example when the build fails.
    deadline = time.time() + timeout
    while not done.is_set() and time.time() < deadline and reading.is_alive():
        done.wait(0.2)
    ok = done.is_set()
    if app_id[0] and p.poll() is None:
        try:
            p.stdin.write(json.dumps([{'id': 1, 'method': 'app.stop',
                                       'params': {'appId': app_id[0]}}]) + '\n')
            p.stdin.flush()
        except (OSError, ValueError):
            pass
    try:
        p.wait(timeout=60)
    except subprocess.TimeoutExpired:
        p.kill()
    if not ok:
        print(f'{device}: no first frame (the run ended or {timeout}s passed); last lines:', flush=True)
        print('\n'.join(raw[-15:]), flush=True)
        return None
    return marks


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(2)
    project = args[0]
    rounds = int(args[args.index('--rounds') + 1]) if '--rounds' in args else 3
    devices = (args[args.index('--devices') + 1].split(',') if '--devices' in args
               else [host_device(), 'raccoon'])
    flutter = args[args.index('--flutter') + 1] if '--flutter' in args else 'flutter'
    clean = '--warm' not in args
    results = {d: [] for d in devices}
    for i in range(rounds):
        for device in devices:
            marks = run(project, flutter, device, clean, timeout=600)
            if marks:
                results[device].append(marks['first frame'])
                print(f'{device:8s} round {i + 1}: first frame {marks["first frame"]:.1f}s '
                      f'(app.started {marks.get("app.started", 0):.1f}s)', flush=True)
    print(f'\n{"clean" if clean else "warm"} build to first frame, {platform.system()} {platform.machine()}')
    for device, times in results.items():
        if not times:
            continue
        times.sort()
        print(f'  {device:8s} runs {len(times)}  median {times[len(times) // 2]:.1f}s  '
              f'min {times[0]:.1f}s  max {times[-1]:.1f}s')


if __name__ == '__main__':
    main()
