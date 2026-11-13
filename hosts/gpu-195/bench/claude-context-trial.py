"""Read-only long-context recall smoke test through the local Claude Code launcher.

Usage: python3 claude-context-trial.py LAUNCHER [--model MODEL] [--cwd PROJECT]
Results and debug logs are written to a new temporary directory.
This tests serving capacity and simple recall, not general long-context quality.
"""
import argparse, json, subprocess, tempfile, time
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('launcher')
parser.add_argument('--model', default='flash-next-huihui')
parser.add_argument('--cwd', default='.')
args=parser.parse_args()
launcher=str(Path(args.launcher).resolve())
model=args.model
root=Path(tempfile.mkdtemp(prefix='claude-context-trial-'))
print(f'Artifacts: {root}', flush=True)
rows=[f'record {i:05d}: latency_ms={i%211:03d} status=ok shard={i%17:02d}' for i in range(2600)]
markers=['CEDAR-7421','ORBIT-5938','MAPLE-2604']
for pos,value in zip([20,1300,2570],markers): rows[pos]=f'CHECKPOINT: {value}'
prompt='This is a synthetic context-window test. Do not use tools or modify files. Read these logs, then reply with only the three CHECKPOINT values in their order of appearance.\n'+'\n'.join(rows)
results=[]
def run(label,prompt,session=None):
 args=[launcher,model,'--output-format','json','--debug-file',str(root/f'{label}-debug.txt'),'-p']
 if session: args.extend(['--resume',session])
 started=time.monotonic()
 p=subprocess.run(args,input=prompt,text=True,capture_output=True,cwd=args.cwd,timeout=600)
 (root/f'{label}.json').write_text(p.stdout);(root/f'{label}-stderr.txt').write_text(p.stderr)
 if p.returncode: raise RuntimeError(f'Claude exited {p.returncode}: {p.stderr[-1000:]}')
 d=json.loads(p.stdout)
 out={k:d.get(k) for k in ['result','session_id','is_error','modelUsage','usage','num_turns']}
 out.update(label=label,seconds=round(time.monotonic()-started,2),markers_correct=all(m in d.get('result','') for m in markers))
 results.append(out);(root/'results.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(out),flush=True)
 return d['session_id']
session=run('long',prompt)
run('followup','Repeat the three CHECKPOINT values from my previous message in the same order. No tools or file changes.',session)

if not all(r['markers_correct'] and not r['is_error'] for r in results):
    raise SystemExit('Context recall smoke test failed; inspect results.json')
