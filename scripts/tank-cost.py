import json,glob,os,time,collections
# input, output, cache-read, cache-write(5m) per MTok
P={'fable-5-1':(10,50,.25,12.5),'fable-5':(10,50,1,12.5),'opus':(5,25,.5,6.25),'sonnet':(2,10,.2,2.5),'haiku':(1,5,.1,1.25)}
def fam(m):
  for k in P:
    if k in m: return k
cut=time.time()-7*86400
seen=set();S=collections.defaultdict(lambda:[0,0,0,0,0.0]);ctx=collections.defaultdict(list);sub=collections.defaultdict(lambda:[0,0.0])
for f in glob.glob(os.path.expanduser('~/.clikae/profiles/claude/*/projects/**/*.jsonl'),recursive=True):
  if os.path.getmtime(f)<cut: continue
  isagent=os.path.basename(f).startswith('agent')
  for l in open(f,errors='ignore'):
    try:d=json.loads(l)
    except:continue
    m=d.get('message') or {};u=m.get('usage');mid=m.get('id')
    if not u or not mid or mid in seen:continue
    seen.add(mid);k=fam(m.get('model',''))
    if not k:continue
    i,o,r,w=P[k];inp=u.get('input_tokens',0);out=u.get('output_tokens',0);cr=u.get('cache_read_input_tokens',0)
    cw=u.get('cache_creation_input_tokens',0)
    c=(inp*i+out*o+cr*r+cw*w)/1e6
    a=S[k];a[0]+=1;a[1]+=inp+cr+cw;a[2]+=out;a[3]+=cr;a[4]+=c
    ctx[k].append(inp+cr+cw);sub[(k,isagent)][0]+=1;sub[(k,isagent)][1]+=c
for k,a in S.items():
  xs=sorted(ctx[k]);n=len(xs)
  print(f"{k:9} calls={a[0]:6} avgctx={a[1]/a[0]/1e3:6.0f}K p50={xs[n//2]/1e3:5.0f}K p90={xs[int(n*.9)]/1e3:5.0f}K out/call={a[2]/a[0]:5.0f} cost=${a[4]:6.0f} readshare={a[3]*P[k][2]/1e6/a[4]:.0%}")
print('total',round(sum(a[4] for a in S.values())))
for (k,ag),v in sorted(sub.items()):print(k,'agent' if ag else 'main ',v[0],round(v[1]))
