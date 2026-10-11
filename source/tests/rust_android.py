"""Isolated Rust tests. Never install, reboot, or change the live mount config."""
import argparse, json, pathlib, shlex, subprocess, time
p=argparse.ArgumentParser();p.add_argument('--serial',required=True);a=p.parse_args()
rootdir=pathlib.Path(__file__).resolve().parents[2]
base='/data/local/tmp/yaw1495-test'; source=base+'/source-'+str(time.time_ns()); adb=['adb','-s',a.serial]
evidence=rootdir.parent/'mount1495-evidence';evidence.mkdir(exist_ok=True)
def root(cmd,check=True):
 r=subprocess.run(adb+['shell','su -c '+shlex.quote(cmd)],capture_output=True,text=True,encoding='utf8',timeout=60)
 if check and r.returncode:raise RuntimeError((cmd,r.returncode,r.stdout,r.stderr))
 return r
def push(path,dest):
 subprocess.run(adb+['push',str(path),'/data/local/tmp/yaw1495-push'],check=True,capture_output=True)
 root('cp /data/local/tmp/yaw1495-push '+shlex.quote(dest))
def put(text,dest):
 f=evidence/'fixture.tmp';f.write_text(text,encoding='utf8',newline='\n');push(f,dest)
binary=rootdir/'source/mountctl/target/aarch64-linux-android/release/mountctl'
root(f'mkdir -p {base}/module/bin {base}/runtime/parsed')
# Stop only the previous isolated test watcher, using its verified process record.
root(f'{base}/module/bin/mounttx watch-signal {base}/runtime/watch.rust.supervisor process',False)
for _ in range(100):
 if root(f'{base}/module/bin/mounttx watch-live {base}/runtime/watch.rust.supervisor',False).returncode:break
 time.sleep(.05)
else:raise AssertionError('old test watcher did not exit')
push(binary,base+'/module/bin/mounttx')
root(f'chmod 755 {base}/module/bin/mounttx; ln -sf mounttx {base}/module/bin/mount.fuse3; ln -sf mounttx {base}/module/bin/mount_fusefs; cp /data/adb/modules/dcimswitch/bin/bindfs {base}/module/bin/bindfs; chmod 755 {base}/module/bin/*')
unit=next((rootdir/'source/mountctl/target/aarch64-linux-android/release/deps').glob('mountctl-*'))
units=[p for p in (rootdir/'source/mountctl/target/aarch64-linux-android/release/deps').glob('mountctl-*') if p.suffix=='']
unit=max(units,key=lambda p:p.stat().st_mtime)
push(unit,base+'/unit-tests');root(f'chmod 755 {base}/unit-tests')
out=root(f'{base}/unit-tests --test-threads=1')
(evidence/'transaction.txt').write_text(out.stdout+out.stderr,encoding='utf8');print(out.stdout,flush=True)
put('#!/system/bin/sh\nprintf "%s\\n" "$2" >> '+base+'/events\n',base+'/module/service.sh')
root(f'mkdir -p {source}; : > {base}/events')
put('initial\n',base+'/mount.conf')
put(f'test|0|{source}|target|lower|visible|1|||preserve|0|none\n',base+'/runtime/parsed/mounts.desired')
root(f'setsid {base}/module/bin/mounttx watch {base}/module {base}/runtime {base}/stopped </dev/null >{base}/watch.log 2>&1 &')
def events():return root(f'cat {base}/events').stdout.splitlines()
def await_count(name,count):
 for _ in range(100):
  if events().count(name)>=count:return
  time.sleep(.05)
 raise AssertionError((name,count,events(),root(f'cat {base}/watch.log').stdout))
try:
 await_count('recover',1);await_count('unlock:0',1);await_count('source',1)
 root(f'mkdir -p {base}/dup; {base}/module/bin/mounttx watch {base}/module {base}/runtime {base}/stopped')
 assert events().count('recover')==1
 put('changed\n',base+'/mount.conf');await_count('config',1)
 root(f'touch {base}/mount.conf');time.sleep(.3);assert events().count('config')==1
 root(f'rmdir {source}');time.sleep(.2);assert events().count('source')==1
 root(f'mkdir {source}');await_count('source',2)
 root(f'touch {source}/content');time.sleep(.3);assert events().count('source')==2
 # Native property-specific futex wait and blocking poll: measure every thread.
 def sample():
  out=root(f'cat /proc/uptime; read p rest < {base}/runtime/watch.rust.supervisor; echo PID=$p; for t in /proc/$p/task/*; do echo TID=${{t##*/}}; cat "$t/schedstat" "$t/wchan"; echo; done').stdout
  return out
 before=sample();time.sleep(30);after=sample();(evidence/'watch-cpu.txt').write_text(before+'\nAFTER\n'+after,encoding='utf8');print(before,after,flush=True)
 print('PASS: singleton, config content dedup, source removal/recreation, content writes ignored',flush=True)
finally:
 root(f'{base}/module/bin/mounttx watch-signal {base}/runtime/watch.rust.supervisor process',False)
