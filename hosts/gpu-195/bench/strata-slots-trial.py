import concurrent.futures,http.client,json,time,sys,statistics
from pathlib import Path
label=sys.argv[1]
prompts=['Write a detailed Python implementation of an LRU cache using OrderedDict, followed by example tests. Keep writing code until finished.','Write a detailed Python implementation of merging overlapping intervals, followed by example tests. Keep writing code until finished.']
def request(prompt):
 c=http.client.HTTPConnection('127.0.0.1',10003,timeout=300)
 body={'model':'flash-next','messages':[{'role':'user','content':prompt}],'max_tokens':256,'temperature':0,'stream':True,'stream_options':{'include_usage':True},'chat_template_kwargs':{'enable_thinking':False},'experimental_speed_projection':True}
 start=time.monotonic();c.request('POST','/v1/chat/completions',json.dumps(body),{'Content-Type':'application/json'})
 r=c.getresponse();assert r.status==200,(r.status,r.read())
 first=None;usage={};text=''
 for line in r:
  if not line.startswith(b'data: '):continue
  raw=line[6:].strip()
  if raw==b'[DONE]':break
  d=json.loads(raw)
  if d.get('usage'):usage=d['usage']
  for ch in d.get('choices',[]):
   t=ch.get('delta',{}).get('content','') or ''
   if t and first is None:first=time.monotonic()
   text+=t
 end=time.monotonic();c.close()
 return {'elapsed':end-start,'ttft':None if first is None else first-start,'usage':usage,'chars':len(text)}
request('Say ready.')
rounds=[]
for _ in range(2):
 start=time.monotonic()
 with concurrent.futures.ThreadPoolExecutor(2) as pool: rows=list(pool.map(request,prompts))
 wall=time.monotonic()-start
 total=sum(x['usage'].get('completion_tokens',0) for x in rows)
 rounds.append({'wall_seconds':wall,'aggregate_tokens_per_second':total/wall,'requests':rows})
c=http.client.HTTPConnection('127.0.0.1',10003);c.request('GET','/metrics');m=json.loads(c.getresponse().read());c.close()
print(json.dumps({'label':label,'aggregate_median':statistics.median(r['aggregate_tokens_per_second'] for r in rounds),'rounds':rounds,'engine':m['engine'],'cache':m['conversation_cache']},indent=2),flush=True)
