import json,glob,os,time,collections
P={'fable-5-1':(10,50,.25,12.5),'fable-5':(10,50,1,12.5),'opus':(5,25,.5,6.25),'sonnet':(2,10,.2,2.5),'haiku':(1,5,.1,1.25)}
fam=lambda m:next((k for k in P if k in m),None)
cut=time.time()-7*86400;seen=set()
A=collections.defaultdict(lambda:[0,0,0.0,''])  # calls,maxctx,cost,model
for f in glob.glob(os.path.expanduser('~/.clikae/profiles/claude/*/projects/**/*.jsonl'),recursive=True):
  if os.path.getmtime(f)<cut:continue
  kind='agent' if os.path.basename(f).startswith('agent') else 'main'
  for l in open(f,errors='ignore'):
    try:d=json.loads(l)
    except:continue
    m=d.get('message') or {};u=m.get('usage');mid=m.get('id')
    if not u or not mid or mid in seen:continue
    seen.add(mid);k=fam(m.get('model',''))
    if not k:continue
    i,o,r,w=P[k];inp=u.get('input_tokens',0);cr=u.get('cache_read_input_tokens',0);cw=u.get('cache_creation_input_tokens',0)
    a=A[(kind,f)];a[0]+=1;a[1]=max(a[1],inp+cr+cw);a[2]+=(inp*i+u.get('output_tokens',0)*o+cr*r+cw*w)/1e6;a[3]=k
for kind in('agent','main'):
  xs=sorted((v for (k,f),v in A.items() if k==kind),key=lambda v:-v[2]);n=len(xs);T=sum(v[2] for v in xs)
  print(kind,'n=',n,'total$',round(T))
  top=xs[:max(1,n//10)];print(' top10% share',f"{sum(v[2] for v in top)/T:.0%}",'median calls',sorted(v[0] for v in xs)[n//2],'p90 calls',sorted(v[0] for v in xs)[int(n*.9)])
  for v in xs[:6]:print('  ',v[3],'calls',v[0],'maxctx',round(v[1]/1e3),'K $',round(v[2]))
  cheap=[v for v in xs if v[0]<=20];print(' agents<=20 calls:',len(cheap),'share',f"{sum(v[2] for v in cheap)/T:.0%}")
