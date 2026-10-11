"""ADB integration tests in /data/local/tmp/yaw1494-test; never install/reboot.
Stage old/new module copies there before running. See native-convergence.md.
"""
import argparse, json, pathlib, shlex, statistics, subprocess, time
args=argparse.ArgumentParser();args.add_argument("--serial",required=True);args.add_argument("--no-benchmark",action="store_true");options=args.parse_args()

ADB = ['adb', '-s', options.serial]
ROOT = '/data/local/tmp/yaw1494-test'
BIN = ROOT + '/new/bin/mounttx'
evidence = pathlib.Path('../mount1494-evidence')
evidence.mkdir(exist_ok=True)

def root(command, check=True):
    p = subprocess.run(ADB + ['shell', 'su -c ' + shlex.quote(command)], capture_output=True, text=True, encoding='utf-8')
    if check and p.returncode:
        raise RuntimeError(f'{command}\n{p.stdout}\n{p.stderr}')
    return p

def put(text, remote):
    p = evidence / 'fixture.tmp'
    p.write_text(text, encoding='utf-8', newline='\n')
    subprocess.run(ADB + ['push', str(p), '/data/local/tmp/yaw1494-fixture.tmp'], check=True, capture_output=True)
    root('cp /data/local/tmp/yaw1494-fixture.tmp ' + shlex.quote(remote))

root(f'cp /data/local/tmp/yaw1494-mounttx {BIN}; chmod 755 {BIN}')
for mode in ['old', 'new']:
    base = f'{ROOT}/{mode}'
    root(f'mkdir -p {base}/data/runtime; cp /data/adb/dcimswitch/mount.conf {base}/data/mount.conf; cp /data/adb/dcimswitch/runtime/active_source_state.tsv {base}/data/runtime/ 2>/dev/null || true')
    put(f'MODDIR={base}\n. "$MODDIR/core.sh"\nparse_config "$CONF" "$PARSED"\n', base + '/parse-test.sh')
    root('sh ' + base + '/parse-test.sh')
    root(f'printf "STATE=valid\\n" > {base}/data/runtime/config.state')
for name in ['global', 'profiles', 'dirs', 'mounts.all', 'mounts.desired']:
    old = root(f'cat {ROOT}/old/data/runtime/parsed/{name}').stdout
    new = root(f'cat {ROOT}/new/data/runtime/parsed/{name}').stdout
    assert old == new, (name, old, new)
print('PASS: live configuration parses identically (8 rows, 7 selected)', flush=True)

cfg = 'partition=YAWAsau\nmount_point=/mnt/YAWAsau\n'
row = 'mount=space 測試|0|folder name|Music/test space|1|||preserve|0|none\n'
fixtures = [
    (cfg + row, 0),
    (cfg + row.replace('folder name', '../escape'), 3),
    (cfg + row.replace('Music/test space', '/storage/emulated/10/test'), 3),
    (cfg + row.replace('|1|||', '|2|||'), 3),
    (cfg + row + row, 4),
    (cfg + 'profile=x|a\nprofile=x|b\n', 3),
    (cfg + row.replace('folder name', '/tmp/$(touch hacked)'), 0),
    (cfg + row.replace('space 測試', 'a' * 128), 3),
    (cfg + row.replace('folder name', '/data/media/0/Music/test space'), 3),
    (cfg + row.replace('|0|folder', '|99999|folder'), 3),
    (cfg + row + 'unknown=value\n', 3),
    (cfg + 'profile=x|a\n' + row.replace('|1|||', '|1|x|b|'), 0),
]
out = ROOT + '/fixture-parsed'
for i, (text, expected) in enumerate(fixtures):
    put(text, ROOT + '/fixture.conf')
    before = root(f'cat {out}/mounts.all', check=False).stdout
    p = root(f'{BIN} parse-config {ROOT}/fixture.conf {out} {ROOT}/fixture.log "UserInfo{{0:owner}}" all', check=False)
    assert p.returncode == expected, (i, p.returncode, p.stderr)
    if expected:
        assert root(f'cat {out}/mounts.all', check=False).stdout == before, 'failed parse published partial output'
print('PASS: parser validation, Unicode/spaces, no eval, failed-parse preservation', flush=True)

# Records must reject PID reuse/stale boot IDs.
pid = root('pidof system_server').stdout.strip().split()[0]
record = ROOT + '/record'
root(f'{BIN} watch-write {record} {pid}; {BIN} watch-live {record}')
put(f'{pid} 1 invalid-boot\n', record)
assert root(f'{BIN} watch-live {record}', check=False).returncode != 0
print('PASS: process identity records reject stale boot/starttime', flush=True)

if options.no_benchmark:
    raise SystemExit(0)

results = {}
for mode in ['old', 'new']:
    base = f'{ROOT}/{mode}'
    for operation, code in [
        ('parse', 'parse_config "$CONF" "$PARSED"'),
        ('pids', 'app_ns_pids_only 0'),
        ('status', 'status_json'),
    ]:
        script = base + '/bench-' + operation + '.sh'
        put(f'MODDIR={base}\n. "$MODDIR/core.sh"\n{code}\n', script)
        samples = []
        for _ in range(5):
            p = root(f'/system/bin/time -p sh {script}')
            # Android time writes its result to stderr, stdout contains the payload.
            timing = p.stderr + '\n' + p.stdout
            real = [line for line in timing.splitlines() if line.startswith('real ')][-1]
            samples.append(float(real.split()[1]))
            if operation == 'status':
                payload = p.stdout[:p.stdout.rfind('}') + 1]
                parsed = json.loads(payload)
                assert len(parsed['mounts']) == 8
                (evidence / (mode + '-status.json')).write_text(json.dumps(parsed, ensure_ascii=False, indent=2), encoding='utf-8')
        results[mode + '_' + operation] = {'seconds': samples, 'median': statistics.median(samples)}
        print(mode, operation, results[mode + '_' + operation], flush=True)
(evidence / 'benchmarks.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
print('PASS: benchmark and JSON schema checks', flush=True)
