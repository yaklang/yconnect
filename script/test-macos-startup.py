#!/usr/bin/env python3
"""Verify packaged startup via Launch Services and its executable in disposable CI."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--disposable-account', action='store_true', required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    app = args.app.resolve()
    binary = app / 'Contents/MacOS/YConnect'
    diagnostics = Path.home() / 'Library/Application Support/YConnect/Diagnostics'
    results = []
    try:
        for index, mode in enumerate(['launch-services', 'direct'], 1):
            before = set(diagnostics.glob('startup-*.json'))
            command = ['open', '-n', '-W', str(app)] if mode == 'launch-services' else [str(binary)]
            with (args.output / f'launch-{index}.log').open('w') as output:
                process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT)
                pid = None
                try:
                    deadline = time.monotonic() + 25
                    report = None
                    while time.monotonic() < deadline:
                        reports = set(diagnostics.glob('startup-*.json')) - before
                        if reports:
                            report_path = next(iter(reports))
                            report = json.loads(report_path.read_text())
                            pid = report['processID']
                            if report['stage'] in ['widgetVisible', 'managerVisible']:
                                break
                        if process.poll() is not None:
                            break
                        time.sleep(0.25)
                    assert report and report['stage'] in ['widgetVisible', 'managerVisible'], report
                    time.sleep(5)
                    assert process.poll() is None, 'application exited during startup'
                    os.kill(pid, 0)
                    updated = report['updatedAt']
                    subprocess.run(['open', str(app)], check=True, timeout=10)
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        report = json.loads(report_path.read_text())
                        if report['updatedAt'] > updated and report['stage'] in ['widgetVisible', 'managerVisible']:
                            break
                        time.sleep(0.25)
                    assert report['updatedAt'] > updated, 'Finder reopen did not present a window'
                    assert report['processID'] == pid, 'Finder reopen started a different process'
                    results.append(dict(mode=mode, alive=True, reopened=True, report=report))
                    print(json.dumps(results[-1]), flush=True)
                finally:
                    if pid:
                        try:
                            os.kill(pid, signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
        for flag in ['--smoke-startup', '--smoke-login-startup', '--smoke-startup-no-tray',
                     '--smoke-startup-degraded', '--smoke-reopen', '--smoke-widget-focus',
                     '--smoke-widget-transient', '--smoke-edge-widget-focus']:
            result = subprocess.run([str(binary), flag], capture_output=True, text=True, timeout=35)
            (args.output / f'{flag[2:]}.log').write_text(result.stdout + result.stderr)
            assert result.returncode == 0, f'{flag}: {result.stdout}\n{result.stderr}'
            results.append(dict(smoke=flag, passed=True))
    finally:
        (args.output / 'results.json').write_text(json.dumps(results, indent=2))
        (args.output / 'system.txt').write_text(subprocess.check_output(['sw_vers'], text=True))


if __name__ == '__main__':
    main()
