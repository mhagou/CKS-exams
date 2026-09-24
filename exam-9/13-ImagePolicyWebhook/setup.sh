#!/usr/bin/env bash
set -Eeuo pipefail
# Run only on the disposable kubeadm playground, as root on controlplane.
export KUBECONFIG=/etc/kubernetes/admin.conf
BASE=/etc/kubernetes/bouncer
STATE=/var/lib/cks-imagepolicy
MANIFEST=/etc/kubernetes/manifests/kube-apiserver.yaml
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID == 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
for cmd in kubectl systemctl; do command -v "$cmd" >/dev/null || { echo "Missing required playground command: $cmd" >&2; exit 1; }; done
[[ -f $MANIFEST ]]
# Python provides the HTTPS simulator; PyYAML safely edits existing YAML.
packages=()
command -v python3 >/dev/null || packages+=(python3)
python3 -c 'import yaml' 2>/dev/null || packages+=(python3-yaml)
command -v openssl >/dev/null || packages+=(openssl)
command -v curl >/dev/null || packages+=(curl)
if ((${#packages[@]})); then
    command -v apt-get >/dev/null || { echo "Install prerequisites: ${packages[*]}" >&2; exit 1; }
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
fi
# Refuse to overwrite an unrelated scanner/configuration or HTTPS listener.
if [[ ! -f $STATE/owned ]]; then
    kubectl --request-timeout=20s get --raw=/readyz >/dev/null
    [[ ! -e $BASE && ! -e /home/candidate/vulnerable.yaml && ! -e /etc/systemd/system/cks-imagepolicy-scanner.service ]] || {
        echo 'Exercise paths already exist without this lab ownership marker; preserve them and inspect before setup.' >&2; exit 1;
    }
    python3 - <<'PY'
import socket, yaml
p=yaml.safe_load(open('/etc/kubernetes/manifests/kube-apiserver.yaml'))
c=next(c for c in p['spec']['containers'] if c['name']=='kube-apiserver')
args=c.get('command',[])+c.get('args',[])
if any('ImagePolicyWebhook' in a for a in args):
    raise SystemExit('An existing ImagePolicyWebhook configuration must be preserved; use a fresh playground.')
with socket.socket() as s:
    s.bind(('127.0.0.1',443))
PY
    mkdir -p "$STATE" "$BASE"
    cp -a "$MANIFEST" "$STATE/apiserver.original.yaml"
    touch "$STATE/owned"
fi
mkdir -p "$BASE" /home/candidate /var/log/nginx
# Create a dedicated certificate; no changes to cluster CA material.
if [[ ! -s $STATE/scanner.key || ! -s $BASE/ca.crt ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj '/CN=smooth-yak.local' -addext 'subjectAltName=DNS:smooth-yak.local' \
        -addext 'basicConstraints=critical,CA:TRUE' \
        -keyout "$STATE/scanner.key" -out "$BASE/ca.crt" >/dev/null 2>&1
    chmod 600 "$STATE/scanner.key"
fi
cat > "$STATE/scanner.py" <<'PY'
#!/usr/bin/env python3
# Deterministic educational scanner, not a production vulnerability database.
import json, ssl, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class Scanner(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        try:
            review=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))))
            images=[c['image'] for c in review['spec']['containers']]
            denied=any(i in ('nginx:1.16.1','docker.io/library/nginx:1.16.1') for i in images)
            # A request-specific outage probe avoids stopping the shared backend.
            outage=any(i.startswith('cks-scanner.invalid/backend-failure:') for i in images)
            code=503 if outage else (200 if self.path=='/review' else 404)
            payload={'apiVersion':'imagepolicy.k8s.io/v1alpha1','kind':'ImageReview',
                     'status':{'allowed':not denied,'reason':'CKS scanner: vulnerable image denied' if denied else ''}}
            with open('/var/log/nginx/access_log','a') as f:
                f.write(json.dumps({'time':time.time(),'path':self.path,'images':images,
                                    'code':code,'allowed':not denied})+'\n')
            body=json.dumps(payload).encode()
            self.send_response(code)
            self.send_header('Content-Type','application/json')
            self.send_header('Content-Length',str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (ValueError,KeyError):
            self.send_error(400)
server=ThreadingHTTPServer(('127.0.0.1',443),Scanner)
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain('/etc/kubernetes/bouncer/ca.crt','/var/lib/cks-imagepolicy/scanner.key')
server.socket=ctx.wrap_socket(server.socket,server_side=True)
server.serve_forever()
PY
cat > /etc/systemd/system/cks-imagepolicy-scanner.service <<'UNIT'
[Unit]
Description=CKS educational ImageReview scanner
After=network.target
[Service]
ExecStart=/usr/bin/python3 /var/lib/cks-imagepolicy/scanner.py
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
# Add only the lab hostname, preserving unrelated host entries.
python3 - <<'PY'
p='/etc/hosts'
lines=open(p).readlines()
for line in lines:
    fields=line.split('#',1)[0].split()
    if 'smooth-yak.local' in fields[1:] and fields[0]!='127.0.0.1':
        raise SystemExit('smooth-yak.local already resolves to another address in /etc/hosts')
if not any('smooth-yak.local' in l.split('#',1)[0].split()[1:] for l in lines):
    with open(p,'a') as f: f.write('\n127.0.0.1 smooth-yak.local # cks-imagepolicy\n')
PY
systemctl daemon-reload
systemctl enable cks-imagepolicy-scanner.service >/dev/null
systemctl restart cks-imagepolicy-scanner.service
cat > "$BASE/image-policy.yaml" <<'YAML'
imagePolicy:
  kubeConfigFile: /etc/kubernetes/bouncer/kubeconfig
  allowTTL: 1
  denyTTL: 1
  retryBackoff: 10
  defaultAllow: true
YAML
cat > "$BASE/kubeconfig" <<'YAML'
apiVersion: v1
kind: Config
clusters:
- name: scanner
  cluster:
    certificate-authority: /etc/kubernetes/bouncer/ca.crt
    server: https://smooth-yak.local/incomplete
users:
- name: apiserver
  user: {}
contexts:
- name: scanner
  context:
    cluster: scanner
    user: apiserver
current-context: scanner
YAML
# Preserve unrelated admission settings. Only prepare the volume and name
# resolution; leave enabling/integrating this plugin to the candidate.
python3 - <<'PY'
import os, tempfile, yaml
path='/etc/kubernetes/manifests/kube-apiserver.yaml'
base='/etc/kubernetes/bouncer'
p=yaml.safe_load(open(path))
original=yaml.safe_load(open('/var/lib/cks-imagepolicy/apiserver.original.yaml'))
c=next(c for c in p['spec']['containers'] if c['name']=='kube-apiserver')
oc=next(c for c in original['spec']['containers'] if c['name']=='kube-apiserver')
def flags(c):
    a=c.get('command',[])+c.get('args',[])
    out={}
    for i,v in enumerate(a):
        if v.startswith('--'):
            k,sep,val=v.partition('=')
            out[k]=val if sep else (a[i+1] if i+1<len(a) else '')
    return out
old=flags(oc).get('--admission-control-config-file')
admission={'apiVersion':'apiserver.config.k8s.io/v1','kind':'AdmissionConfiguration','plugins':[]}
if old:
    host=old
    volumes={v['name']:v for v in original['spec'].get('volumes',[])}
    for m in sorted(oc.get('volumeMounts',[]),key=lambda m:len(m['mountPath']),reverse=True):
        if old==m['mountPath'] or old.startswith(m['mountPath'].rstrip('/')+'/'):
            host=volumes[m['name']]['hostPath']['path']+old[len(m['mountPath']):]
            break
    admission=yaml.safe_load(open(host))
    # Resolve relative plugin paths before copying the admission document.
    for plugin in admission.get('plugins',[]):
        if plugin.get('path') and not os.path.isabs(plugin['path']):
            plugin['path']=os.path.normpath(os.path.join(os.path.dirname(old),plugin['path']))
admission.setdefault('plugins',[]).append({'name':'ImagePolicyWebhook','path':base+'/image-policy.yaml'})
with open(base+'/admission_configuration.yaml','w') as f: yaml.safe_dump(admission,f,sort_keys=False)
for field in ('command','args'):
    a=c.get(field,[]); out=[]; i=0
    while i<len(a):
        v=a[i]; key,sep,value=v.partition('=')
        if key in ('--enable-admission-plugins','--disable-admission-plugins','--admission-control-config-file'):
            if not sep: i+=1; value=a[i]
            if key=='--admission-control-config-file':
                if old: out.append(key+'='+old)
            else:
                value=','.join(x for x in value.split(',') if x!='ImagePolicyWebhook')
                if value: out.append(key+'='+value)
        else: out.append(v)
        i+=1
    if field in c: c[field]=out
volumes=p['spec'].setdefault('volumes',[])
mounts=c.setdefault('volumeMounts',[])
if not any(m['mountPath']==base for m in mounts):
    name='cks-bouncer'
    if any(v['name']==name for v in volumes): raise SystemExit('Lab volume name conflict')
    volumes.append({'name':name,'hostPath':{'path':base,'type':'Directory'}})
    mounts.append({'name':name,'mountPath':base,'readOnly':True})
aliases=p['spec'].setdefault('hostAliases',[])
for entry in aliases:
    if 'smooth-yak.local' in entry.get('hostnames',[]) and entry['ip']!='127.0.0.1':
        raise SystemExit('Conflicting API server hostname alias')
if not any('smooth-yak.local' in a.get('hostnames',[]) for a in aliases):
    aliases.append({'ip':'127.0.0.1','hostnames':['smooth-yak.local']})
if not p['spec'].get('hostNetwork'): raise SystemExit('Expected kubeadm hostNetwork API server')
# Stage outside the watched directory, then atomically replace the manifest.
fd,tmp=tempfile.mkstemp(dir='/etc/kubernetes',prefix='.cks-apiserver-')
with os.fdopen(fd,'w') as f: yaml.safe_dump(p,f,sort_keys=False)
os.chmod(tmp,os.stat(path).st_mode & 0o777)
os.replace(tmp,path)
PY
cat > /home/candidate/vulnerable.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: vulnerable
  namespace: default
spec:
  containers:
  - name: nginx
    image: nginx:1.16.1
YAML
# Wait for the actual replacement API server process, not the old ready endpoint.
python3 - <<'PY'
import pathlib,time
for _ in range(90):
    for p in pathlib.Path('/proc').glob('[0-9]*/cmdline'):
        try:
            args=p.read_bytes().decode().split('\0')
            if pathlib.Path(args[0]).name!='kube-apiserver': continue
            hosts=(p.parent/'root/etc/hosts').read_text()
            if ('smooth-yak.local' in hosts
                    and (p.parent/'root/etc/kubernetes/bouncer/kubeconfig').is_file()
                    and not any('ImagePolicyWebhook' in a for a in args)):
                raise SystemExit(0)
        except (FileNotFoundError,PermissionError,IndexError): pass
    time.sleep(2)
raise SystemExit('Prepared API server did not become active')
PY
ready=false
for ((i=0;i<90;i++)); do
    if kubectl --request-timeout=5s get --raw=/readyz >/dev/null 2>&1; then ready=true; break; fi
    sleep 2
done
$ready
systemctl is-active --quiet cks-imagepolicy-scanner.service
for image in nginx:1.16.1 registry.k8s.io/pause:3.10; do
    curl --noproxy '*' --fail --silent --show-error --retry 5 --retry-connrefused \
        --connect-timeout 5 --max-time 15 --resolve smooth-yak.local:443:127.0.0.1 --cacert "$BASE/ca.crt" \
        -H 'Content-Type: application/json' \
        -d "{\"spec\":{\"containers\":[{\"image\":\"$image\"}]}}" \
        https://smooth-yak.local/review | python3 -c \
        'import json,sys; r=json.load(sys.stdin); assert r["status"]["allowed"] == (sys.argv[1] != "nginx:1.16.1")' "$image"
done
# Dry-run only: the insecure test image is never started during preparation.
python3 - <<'PYPROBE' | kubectl --request-timeout=20s create --dry-run=server -f - >/dev/null
import json, uuid, yaml
pod=yaml.safe_load(open('/home/candidate/vulnerable.yaml'))
pod['metadata']['name']='cks-initial-'+uuid.uuid4().hex[:12]
print(json.dumps(pod))
PYPROBE
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
