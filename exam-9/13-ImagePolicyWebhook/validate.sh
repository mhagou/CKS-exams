#!/usr/bin/env bash
set -Eeuo pipefail
# Read-only inspection and server-side dry-run requests; no configuration repairs.
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
if [[ $EUID != 0 ]] || ! command -v python3 >/dev/null || ! command -v kubectl >/dev/null || ! python3 -c 'import yaml' 2>/dev/null; then
    printf '[FAIL] Run as root with kubectl, Python 3 and PyYAML (provided by setup).\nTotals: 0 passed, 1 failed\nRESULT: FAILED\n'
    exit 1
fi
python3 - <<'PY'
import copy,json,pathlib,subprocess,time,uuid,yaml
passed=failed=0
def report(ok,description):
    global passed,failed
    if ok: passed+=1
    else: failed+=1
    print(('[PASS] ' if ok else '[FAIL] ')+description,flush=True)
def run(args,body=None):
    try:
        r=subprocess.run(['kubectl','--request-timeout=25s']+args,input=body,text=True,capture_output=True,timeout=35)
        return r.returncode==0,r.stdout+r.stderr
    except (OSError,subprocess.TimeoutExpired) as e: return False,str(e)
def flags(args):
    result={}
    for i,a in enumerate(args):
        if a.startswith('--'):
            k,sep,v=a.partition('=')
            result[k]=v if sep else (args[i+1] if i+1<len(args) else '')
    return result
ok,_=run(['get','--raw=/readyz'])
report(ok,'API server is ready')
try:
    processes=[]
    for p in pathlib.Path('/proc').glob('[0-9]*/cmdline'):
        try:
            args=p.read_bytes().decode().split('\0')
            if pathlib.Path(args[0]).name=='kube-apiserver': processes.append((p.parent,flags(args)))
        except (OSError,UnicodeError,IndexError): pass
    if len(processes)!=1: raise ValueError('Expected one active local kube-apiserver; retry after restart settles')
    proc,opts=processes[0]
    def read_config(path,relative_to='/'):
        target=pathlib.PurePosixPath(path)
        if not target.is_absolute(): target=pathlib.PurePosixPath(relative_to)/target
        return yaml.safe_load((proc/'root'/str(target).lstrip('/')).read_text())
    enabled=opts.get('--enable-admission-plugins','').split(',')
    disabled=opts.get('--disable-admission-plugins','').split(',')
    admission_path=opts.get('--admission-control-config-file','')
    admission=read_config(admission_path) if admission_path else {}
    plugins=admission.get('plugins',[])
    plugin=next((p for p in plugins if p.get('name')=='ImagePolicyWebhook'),None)
    report('ImagePolicyWebhook' in enabled and 'ImagePolicyWebhook' not in disabled and plugin is not None,
           'Running API server enables ImagePolicyWebhook and references its admission configuration')
    if plugin is None: raise ValueError('No ImagePolicyWebhook entry in active AdmissionConfiguration')
    config=plugin.get('configuration')
    if config is None:
        config=read_config(plugin['path'],str(pathlib.PurePosixPath(admission_path).parent))
    policy=config['imagePolicy']
    report(policy.get('defaultAllow') is False,'Active configuration specifies deny on backend failure')
    kube=read_config(policy['kubeConfigFile'])
    context=next(c['context'] for c in kube['contexts'] if c['name']==kube['current-context'])
    cluster=next(c['cluster'] for c in kube['clusters'] if c['name']==context['cluster'])
    report(cluster.get('server')=='https://smooth-yak.local/review','Selected backend points to the required HTTPS scanner endpoint')
except (OSError,KeyError,ValueError,TypeError,StopIteration,yaml.YAMLError) as e:
    report(False,'Inspect active admission configuration: '+str(e))

# Use the supplied test resource with a fresh name and review annotation. These
# requests exercise admission but never persist or start a vulnerable container.
# The annotation also makes reviews unique despite the webhook decision cache.
try:
    template=yaml.safe_load(pathlib.Path('/home/candidate/vulnerable.yaml').read_text())
    if template.get('kind')!='Pod': raise ValueError('The supplied test resource must remain a Pod')
    images=[c['image'] for c in template['spec']['containers']]
    if not any(i in ('nginx:1.16.1','docker.io/library/nginx:1.16.1') for i in images):
        raise ValueError('The provided vulnerable test image has been removed')
    nonce=uuid.uuid4().hex[:16]
    def probe(kind,image=None):
        pod=copy.deepcopy(template)
        pod['metadata']={'name':'cks-imagepolicy-'+kind+'-'+nonce,
                         'namespace':template.get('metadata',{}).get('namespace','default'),
                         'annotations':{'cks.image-policy.k8s.io/probe':kind+'-'+nonce}}
        pod.pop('status',None)
        if image:
            pod['spec']={'restartPolicy':'Never','containers':[{'name':'probe','image':image}]}
        return run(['create','--dry-run=server','-f','-','-o','name'],json.dumps(pod))
    good,output=probe('allowed','registry.k8s.io/pause:3.10')
    report(good,'Scanner permits a benign control Pod')
    if not good: print('  '+output.strip()[:1000])
    rejected,output=probe('vulnerable')
    report(not rejected and 'CKS scanner: vulnerable image denied' in output,
           'Supplied vulnerable resource is rejected by the image scanner')
    if rejected or 'CKS scanner: vulnerable image denied' not in output: print('  '+output.strip()[:1000])
    failure_image='cks-scanner.invalid/backend-failure:'+nonce
    start=time.time()
    accepted,output=probe('failure',failure_image)
    log=pathlib.Path('/var/log/nginx/access_log')
    records=[]
    if log.exists():
        with log.open() as f:
            for line in f:
                try: records.append(json.loads(line))
                except ValueError: pass # Preserve compatibility with unrelated nginx log entries.
    outage_seen=any(r.get('time',0)>=start and r.get('path')=='/review' and r.get('code')==503
                    and failure_image in r.get('images',[]) for r in records)
    # Require a scanner-specific transport failure, not unrelated RBAC/quota/PSA rejection.
    policy_error='image policy' in output.lower() or 'imagepolicywebhook' in output.lower()
    report(good and not accepted and outage_seen and policy_error,
           'Backend HTTP failure rejects admission at runtime')
    if accepted or not outage_seen or not policy_error: print('  '+output.strip()[:1000])
    denied_seen=any(r.get('path')=='/review' and r.get('code')==200 and r.get('allowed') is False
                    and any(i in r.get('images',[]) for i in images) for r in records)
    report(denied_seen,'Scanner access log records a vulnerable-image review')
except (OSError,KeyError,ValueError,TypeError,yaml.YAMLError) as e:
    report(False,'Exercise runtime admission tests: '+str(e))
print(f'Totals: {passed} passed, {failed} failed')
print('RESULT: SUCCESS' if failed==0 else 'RESULT: FAILED')
raise SystemExit(0 if failed==0 else 1)
PY
