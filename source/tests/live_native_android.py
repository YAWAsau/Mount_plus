"""Explicit live spare-device test: add isolated mounts, then restore exact config.
Run only with user authorization, after backing up the installed module/config.
"""
import argparse, json, pathlib, shlex, subprocess, time
p=argparse.ArgumentParser();p.add_argument('--serial',required=True);p.add_argument('--live',action='store_true');a=p.parse_args()
if not a.live: raise SystemExit('Requires --live and an authorized spare device')
adb=['adb','-s',a.serial];module='/data/adb/modules/dcimswitch';data='/data/adb/dcimswitch'
evidence=pathlib.Path('../mount1494-evidence');evidence.mkdir(exist_ok=True)
def run(cmd,check=True):
    r=subprocess.run(adb+['shell','su -c '+shlex.quote(cmd)],capture_output=True,text=True,encoding='utf-8',timeout=180)
    if check and r.returncode:raise RuntimeError((cmd,r.stdout,r.stderr))
    return r
def reload_manual():
    for _ in range(30):
        r=run(f'sh {module}/control.sh reload manual',check=False)
        if r.returncode==0:return
        if r.returncode!=4:raise RuntimeError(('reload',r.returncode,r.stderr))
        time.sleep(1)
    raise RuntimeError('reload lock remained busy')
def status():return json.loads(run(f'sh {module}/control.sh status').stdout)
def wait_ready(names,timeout=90):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        s=status();rows={r['name']:r for r in s['mounts']}
        if all(n in rows and rows[n]['mounted'] and rows[n]['visible'] for n in names):return s
        time.sleep(1)
    raise AssertionError(('mount readiness timeout',s))
original=run(f'cat {data}/mount.conf').stdout
# Remote cp preserves exact bytes, including original line endings.
backup='/data/local/tmp/yaw1494-live-original.conf'
run(f'cp -p {data}/mount.conf {backup}')
before=status();before=wait_ready([r['name'] for r in before['mounts'] if r['active']])
sources=['/data/yaw1494-test-kernel-a','/data/yaw1494-test-kernel-b','/data/yaw1494-test-fuse']
for src in sources:
    run(f'test ! -e {src}; mkdir {src}; printf original > {src}/marker.txt')
addition='''
# Isolated native convergence test; removed after validation.
profile=yaw1494|a
mount=YAW1494-KA|0|/data/yaw1494-test-kernel-a|Download/YAW1494_Kernel|1|yaw1494|a|media_rw|0|none
mount=YAW1494-KB|0|/data/yaw1494-test-kernel-b|Download/YAW1494_Kernel|1|yaw1494|b|media_rw|0|none
mount=YAW1494-F|0|/data/yaw1494-test-fuse|Download/YAW1494_Fuse|1|||bindfs_shared|0|none
'''
fixture=evidence/'live.conf';fixture.write_text(original+addition,encoding='utf-8',newline='\n')
subprocess.run(adb+['push',str(fixture),'/data/local/tmp/yaw1494-live.conf'],check=True,capture_output=True)
results=[]
try:
    run(f'cp /data/local/tmp/yaw1494-live.conf {data}/mount.conf.native-test; chmod 600 {data}/mount.conf.native-test; mv {data}/mount.conf.native-test {data}/mount.conf')
    wait_ready(['YAW1494-KA','YAW1494-F']);results.append('config event applied kernel+bindfs mounts')
    for src,name,target in [(sources[0],'YAW1494-KA','YAW1494_Kernel'),(sources[2],'YAW1494-F','YAW1494_Fuse')]:
        run(f'rm {src}/marker.txt; rmdir {src}')
        s=status();r=next(r for r in s['mounts'] if r['name']==name)
        assert not r['mounted'] and not r['visible'],r
        # Restore only our own deleted source, then rely on sourcewatch (no reload).
        start=time.monotonic();run(f'mkdir {src}; printf recovered > {src}/marker.txt')
        wait_ready([name]);elapsed=time.monotonic()-start
        mp=run(f"cat {data}/runtime/media_provider_ns.0.cache").stdout
        pid=next(x.split('=',1)[1] for x in mp.splitlines() if x.startswith('PID='))
        actual=run(f'nsenter -t {pid} -m -- cat /storage/emulated/0/Download/{target}/marker.txt').stdout
        assert actual=='recovered',actual
        results.append(f'{name}: unhealthy while missing; automatic recovery and scanner-namespace content verified ({elapsed:.2f}s)')
        print(results[-1],flush=True)
    run(f'sh {module}/control.sh profile yaw1494 b');wait_ready(['YAW1494-KB','YAW1494-F'])
    run(f'sh {module}/control.sh profile yaw1494 a');wait_ready(['YAW1494-KA','YAW1494-F'])
    results.append('native profile switch a -> b -> a passed')
    reload_manual();wait_ready(['YAW1494-KA','YAW1494-F'])
    results.append('manual remount verified')
    (evidence/'live-status.json').write_text(json.dumps(status(),ensure_ascii=False,indent=2),encoding='utf-8')
finally:
    run(f'cp -p {backup} {data}/mount.conf.native-restore; mv {data}/mount.conf.native-restore {data}/mount.conf')
    reload_manual()
    run(f'cmp {backup} {data}/mount.conf')
    final=wait_ready([r['name'] for r in before['mounts'] if r['active']])
    (evidence/'restored-status.json').write_text(json.dumps(final,ensure_ascii=False,indent=2),encoding='utf-8')
    # Remove only known test files; rmdir refuses unexpected content/mounts.
    for src in sources:run(f'rm -f {src}/marker.txt; rmdir {src}',check=False)
    for target in ['YAW1494_Kernel','YAW1494_Fuse']:
        run(f'nsenter -t 1 -m -- rmdir /data/media/0/Download/{target}',check=False)
    results.append('exact original config restored; original active mounts healthy')
(evidence/'live-results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2),encoding='utf-8')
print('\n'.join(results),flush=True)
