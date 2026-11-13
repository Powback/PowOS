"""Check local session switching, KV reuse, queued cancellation and active interrupts.

Uses synthetic messages through the production local-only Claude authority.
Does not run agent tools. Run while the pool is available; other traffic adds
queue wait to the timings.
"""
import argparse,http.client,json,time,socket,tempfile,uuid
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host', default='claude-auth.pow')
parser.add_argument('--model', default='flash-next-huihui-nothink')
args=parser.parse_args()
OUT=Path(tempfile.mkdtemp(prefix='local-session-trial-'))/'results.json'; results={}
print(f'Artifacts: {OUT}', flush=True)
MODEL=args.model
def save():OUT.write_text(json.dumps(results,indent=2)+'\n')
def request(messages,session,stream=False,max_tokens=96):
 c=http.client.HTTPConnection(args.host,timeout=360)
 b={'model':MODEL,'messages':messages,'max_tokens':max_tokens,'stream':stream,'metadata':{'user_id':json.dumps({'session_id':session})}}
 c.request('POST','/v1/messages',json.dumps(b),{'Content-Type':'application/json','Authorization':'Bearer local-only','anthropic-version':'2023-06-01'})
 return c

def ask(messages,session):
 start=time.monotonic();c=request(messages,session);r=c.getresponse();d=json.loads(r.read());c.close()
 assert r.status==200,(r.status,d)
 text=''.join(x.get('text','') for x in d.get('content',[]) if x.get('type')=='text')
 return {'seconds':round(time.monotonic()-start,3),'text':text,'usage':d.get('usage')},d

def health():
 c=http.client.HTTPConnection(args.host,timeout=5);c.request('GET','/health');r=c.getresponse();d=json.loads(r.read());c.close();return d['localModels']['queues'].get('gpu-pool',{})
def cancel(c):
 if c.sock:
  try:c.sock.shutdown(socket.SHUT_RDWR)
  except OSError:pass
 c.close()

# Sequential A -> unrelated B -> A follow-up, retaining the exact original messages.
aid,bid=str(uuid.uuid4()),str(uuid.uuid4())
a=[{'role':'user','content':'Session A: Return only the secret marker CEDAR-7421. No tools.\n'+'\n'.join(f'A-record {i:05d}: latency_ms={i%211:03d} status=ok shard={i%17:02d}' for i in range(600))}]
b=[{'role':'user','content':'Session B: Return only the secret marker ORBIT-5938. No tools.\n'+'\n'.join(f'B-entry {i:05d}: bytes={i*13:06d} state=ready zone={i%23:02d}' for i in range(600))}]
results['A1'],ad=ask(a,aid);save();print('A1',results['A1'],flush=True)
results['B1'],bd=ask(b,bid);save();print('B1',results['B1'],flush=True)
a += [{'role':'assistant','content':ad['content']},{'role':'user','content':'Repeat my secret marker only.'}]
results['A2'],_=ask(a,aid);save();print('A2',results['A2'],flush=True)
assert 'CEDAR-7421' in results['A2']['text']

# Hold one long generation. Cancel a queued request, then interrupt the active one.
ca=request([{'role':'user','content':'Print the integers 1 through 2000, one per line. Do not skip numbers or explain. Begin now.'}],str(uuid.uuid4()),True,4096)
ra=ca.getresponse();assert ra.status==200
while True:
 line=ra.readline()
 assert line,'stream ended before output'
 if line.startswith(b'data: '):
  d=json.loads(line[6:])
  if d.get('type')=='content_block_delta' and d.get('delta',{}).get('text'):break
cb=request([{'role':'user','content':'Reply with SHOULD-NOT-RUN.'}],str(uuid.uuid4()),True)
cc=request([{'role':'user','content':'Reply with exactly INTERRUPT-OK.'}],str(uuid.uuid4()),True)
for _ in range(100):
 state=health()
 if state.get('waiting',0)>=2:break
 time.sleep(.05)
assert state.get('waiting',0)>=2,state
results['queued_before_cancel']=state; baseline_cancelled=state.get('cancelled',0);cancel(cb)
for _ in range(100):
 state=health()
 if state.get('cancelled',0)>baseline_cancelled:break
 time.sleep(.05)
assert state.get('cancelled',0)>baseline_cancelled,state
results['queued_after_cancel']=state
start=time.monotonic();cancel(ca);ra.close();rc=cc.getresponse();raw=rc.read().decode();cc.close()
assert rc.status==200,(rc.status,raw)
text=''
for line in raw.splitlines():
 if line.startswith('data: '):
  d=json.loads(line[6:]);assert d.get('type')!='error',d
  text+=d.get('delta',{}).get('text','')
assert 'INTERRUPT-OK' in text,text
results['interrupt']={'next_response_including_other_sessions_seconds':round(time.monotonic()-start,3),'text':text}
results['final_queue']=health();save();print(json.dumps(results['interrupt']),flush=True)
