from pathlib import Path
import sys
root=Path(__file__).resolve().parents[2]
out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
s=(root/'core.sh').read_text(encoding='utf-8')
functions=[]
for name,end in [('visible_probe','visible_probe_retry'),('media_scan_schedule_user_root_if_media_active','media_scan_schedule_initial_roots'),('media_scan_broadcast','media_scan_schedule_path')]:
 functions.append(s[s.index(name+'() {'):s.index('\n'+end+'()',s.index(name+'() {'))])
for name in ['core','control','service','watchers','customize']:
 (out/(name+'.sh')).write_text((root/(name+'.sh')).read_text(encoding='utf-8'),encoding='utf-8',newline='\n')
(out/'test.sh').write_text('#!/system/bin/sh\nset -eu\n'+'\n'.join(functions)+'\n'+(root/'source/tests/shell_assertions_android.sh').read_text(encoding='utf-8'),encoding='utf-8',newline='\n')
