import json,sys
f=sys.argv[1]; n=int(sys.argv[2]) if len(sys.argv)>2 else 40
out=[]
for line in open(f):
    try: e=json.loads(line)
    except: continue
    t=e.get('type')
    if t=='assistant':
        for c in e['message'].get('content',[]):
            if c.get('type')=='text': out.append('TEXT: '+c['text'][:400].replace('\n',' '))
            elif c.get('type')=='tool_use':
                i=c.get('input',{}); d=i.get('description') or i.get('command') or i.get('prompt') or i.get('file_path') or json.dumps(i)[:200]
                out.append('TOOL %s: %s'%(c['name'],str(d)[:200].replace('\n',' ')))
    elif t=='result':
        out.append('RESULT: '+str(e.get('subtype'))+' '+str(e.get('result'))[:1500])
    elif t=='system' and e.get('subtype') not in ('init',):
        out.append('SYS: '+str(e.get('subtype')))
print('\n'.join(out[-n:]))
