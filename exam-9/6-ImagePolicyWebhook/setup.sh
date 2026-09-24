#!/usr/bin/env bash
set -Eeuo pipefail
# Run only on the target playground controlplane, never during generation.
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
base=/etc/kubernetes/epconfig
state=/var/lib/cks-imagepolicy
manifest=/etc/kubernetes/manifests/kube-apiserver.yaml
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID == 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
for cmd in kubectl openssl systemctl python3; do
  if ! command -v "$cmd" >/dev/null; then
    case "$cmd" in
      openssl|python3)
        command -v apt-get >/dev/null || { echo "Install $cmd first." >&2; exit 1; }
        apt-get update -qq; apt-get install -y "$cmd" ;;
      *) echo "Required playground command missing: $cmd" >&2; exit 1 ;;
    esac
  fi
done
if ! python3 -c 'import yaml' 2>/dev/null; then
  command -v apt-get >/dev/null || { echo 'Install python3-yaml first.' >&2; exit 1; }
  apt-get update -qq
  apt-get install -y python3-yaml
fi
[[ -f $manifest ]]
[[ $(kubectl get node controlplane -o jsonpath='{.metadata.name}') == controlplane ]]
kubectl get --raw=/readyz >/dev/null
# Refuse to take ownership of unrelated resources. Backups are outside the watched directory.
python3 - "$base" "$state" "$manifest" <<'PY'
import pathlib, sys, yaml, socket
base, state, manifest = map(pathlib.Path, sys.argv[1:])
owned = (state/'owned').exists()
pod = yaml.safe_load(manifest.read_text())
assert pod['spec'].get('hostNetwork'), 'Expected host-networked control-plane API server'
c = next(c for c in pod['spec']['containers'] if 'kube-apiserver' in c.get('command', [''])[0])
args = c.get('command', []) + c.get('args', [])
if not owned:
    assert not base.exists(), 'Existing epconfig directory: refusing to overwrite it'
    assert not pathlib.Path('/etc/systemd/system/cks-imagepolicy.service').exists(), 'Existing scanner unit'
    assert not any('ImagePolicyWebhook' in a for a in args), 'Existing image policy integration; refusing to reset it'
    assert not any('wakanda.local' in line.split('#')[0].split() for line in pathlib.Path('/etc/hosts').read_text().splitlines()), 'Existing wakanda.local mapping'
    s = socket.socket(); s.bind(('127.0.0.1', 8081)); s.close()
state.mkdir(mode=0o700, parents=True, exist_ok=True)
if not (state/'apiserver.original.yaml').exists():
    (state/'apiserver.original.yaml').write_text(manifest.read_text())
(state/'owned').touch()
PY
mkdir -p "$base"
chmod 700 "$state"
# Self-signed lab CA/server certificate, with a proper DNS SAN.
if [[ ! -s $state/server.key || ! -s $base/webhook.pem ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$state/server.key" -out "$base/webhook.pem" \
    -subj /CN=wakanda.local -addext 'subjectAltName=DNS:wakanda.local' >/dev/null 2>&1
fi
chmod 600 "$state/server.key"
cat > "$state/scanner.py" <<'PY'
# Educational scanner simulator: deterministic fixture verdicts, no live CVE feed.
import http.server, json, ssl
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.path == '/healthz' else 404)
        self.end_headers()
    def do_POST(self):
        if self.path != '/image_policy':
            self.send_error(404); return
        try:
            request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            images = [c['image'] for c in request['spec']['containers']]
        except (ValueError, KeyError, TypeError):
            self.send_error(400); return
        # A unique image tag allows isolated failure testing without service disruption.
        if any(i.startswith('registry.invalid/cks-scan-error:') for i in images):
            body = json.dumps({'apiVersion':'v1','kind':'Status','status':'Failure',
                'reason':'ServiceUnavailable','message':'CKS simulated scanner unavailable','code':503}).encode()
            self.send_response(503); self.send_header('Content-Type','application/json')
            self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
            return
        denied = any(i in ('nginx:1.16', 'docker.io/library/nginx:1.16') for i in images)
        body = json.dumps({'apiVersion':'imagepolicy.k8s.io/v1alpha1',
            'kind':'ImageReview', 'status':{'allowed':not denied,
            'reason':'CKS scanner: vulnerable image fixture' if denied else 'CKS scanner: accepted'}}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json')
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
server = http.server.ThreadingHTTPServer(('127.0.0.1',8081), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain('/etc/kubernetes/epconfig/webhook.pem','/var/lib/cks-imagepolicy/server.key')
server.socket = ctx.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PY
cat > /etc/systemd/system/cks-imagepolicy.service <<'UNIT'
[Unit]
Description=CKS image policy scanner simulator
After=network.target
[Service]
ExecStart=/usr/bin/python3 /var/lib/cks-imagepolicy/scanner.py
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
UNIT
python3 - <<'PY'
from pathlib import Path
p = Path('/etc/hosts')
lines = [l for l in p.read_text().splitlines() if not l.endswith('# cks-imagepolicy')]
p.write_text('\n'.join(lines) + '\n127.0.0.1 wakanda.local # cks-imagepolicy\n')
PY
cat > "$base/admission-config.yaml" <<'YAML'
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
- name: ImagePolicyWebhook
  configuration:
    imagePolicy:
      kubeConfigFile: /etc/kubernetes/epconfig/webhook.kubeconfig
      allowTTL: 50
      denyTTL: 50
      retryBackoff: 500
      defaultAllow: true
YAML
cat > "$base/webhook.kubeconfig" <<'YAML'
apiVersion: v1
kind: Config
clusters:
- name: scanner
  cluster:
    certificate-authority: /etc/kubernetes/epconfig/webhook.pem
    server: https://wakanda.local:8081/incomplete
contexts:
- name: scanner
  context:
    cluster: scanner
    user: scanner
current-context: scanner
users:
- name: scanner
  user: {}
YAML
cat > "$base/README.txt" <<'TXT'
The educational HTTPS scanner is available at https://wakanda.local:8081/image_policy.
It simulates scan verdicts: nginx:1.16 is a vulnerable fixture; registry.k8s.io/pause:3.10 is accepted.
No live vulnerability database is used. Other images are accepted.
The registry.invalid/cks-scan-error:<unique-tag> fixture simulates a scanner error for testing.
The configuration in this directory is intentionally incomplete.
TXT
mkdir -p /root/KSSC00202
if [[ ! -e /root/KSSC00202/vulnerable-resource.yml ]]; then
cat > /root/KSSC00202/vulnerable-resource.yml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: vulnerable-resource
spec:
  containers:
  - name: example
    image: nginx:1.16
YAML
fi
# Supply file visibility and name resolution only; leave admission integration to the candidate.
python3 - "$manifest" <<'PY'
import os, pathlib, sys, tempfile, yaml
p = pathlib.Path(sys.argv[1]); pod = yaml.safe_load(p.read_text()); spec = pod['spec']
c = next(c for c in spec['containers'] if 'kube-apiserver' in c.get('command', [''])[0])
for key in ('command','args'):
    old = c.get(key, []); new = []; i = 0
    while i < len(old):
        a = old[i]; flag, sep, value = a.partition('=')
        if flag in ('--enable-admission-plugins','--disable-admission-plugins','--admission-control-config-file'):
            if not sep:
                i += 1; value = old[i]
            if flag == '--admission-control-config-file':
                if value != '/etc/kubernetes/epconfig/admission-config.yaml':
                    new.append(flag+'='+value)
            else:
                plugins = [x for x in value.split(',') if x != 'ImagePolicyWebhook']
                if plugins: new.append(flag+'='+','.join(plugins))
        else: new.append(a)
        i += 1
    if key in c: c[key] = new
volumes = spec.setdefault('volumes', [])
mounts = c.setdefault('volumeMounts', [])
mount = next((m for m in mounts if m['mountPath'] == '/etc/kubernetes/epconfig'), None)
if mount:
    v = next(v for v in volumes if v['name'] == mount['name'])
    assert v.get('hostPath',{}).get('path') == '/etc/kubernetes/epconfig', 'Conflicting epconfig mount'
else:
    assert not any(v['name'] == 'cks-epconfig' for v in volumes), 'Conflicting volume name'
    volumes.append({'name':'cks-epconfig','hostPath':{'path':'/etc/kubernetes/epconfig','type':'Directory'}})
    mounts.append({'name':'cks-epconfig','mountPath':'/etc/kubernetes/epconfig','readOnly':True})
aliases = spec.setdefault('hostAliases', [])
for a in aliases:
    a['hostnames'] = [h for h in a['hostnames'] if h != 'wakanda.local']
spec['hostAliases'] = [a for a in aliases if a['hostnames']] + [{'ip':'127.0.0.1','hostnames':['wakanda.local']}]
# Atomic replacement; no backup manifests in the kubelet's watched directory.
with tempfile.NamedTemporaryFile(mode='w', dir=p.parent, prefix='.cks-', delete=False) as f:
    yaml.safe_dump(pod, f, sort_keys=False); tmp = f.name
os.chmod(tmp, p.stat().st_mode & 0o777); os.replace(tmp,p)
PY
systemctl daemon-reload
systemctl enable cks-imagepolicy.service >/dev/null
systemctl restart cks-imagepolicy.service
# Check the endpoint over verified TLS and both fixture verdicts.
python3 - <<'PY'
import json, ssl, time, urllib.request
ctx = ssl.create_default_context(cafile='/etc/kubernetes/epconfig/webhook.pem')
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=ctx))
for attempt in range(30):
    try:
        for image, allowed in [('nginx:1.16',False),('registry.k8s.io/pause:3.10',True)]:
            data = json.dumps({'apiVersion':'imagepolicy.k8s.io/v1alpha1','kind':'ImageReview',
                'spec':{'containers':[{'image':image}]}}).encode()
            req = urllib.request.Request('https://wakanda.local:8081/image_policy',data,{'Content-Type':'application/json'})
            assert json.load(opener.open(req,timeout=3))['status']['allowed'] is allowed
        break
    except Exception:
        if attempt == 29: raise
        time.sleep(2)
PY
ready=false
for ((i=0;i<90;i++)); do
  if kubectl --request-timeout=5s get --raw=/readyz >/dev/null 2>&1; then ready=true; break; fi
  sleep 2
done
[[ $ready == true ]]
# Confirm the restarted API server is running without the exercise plugin.
python3 - <<'PY'
import pathlib, time
for attempt in range(90):
    found = []
    for p in pathlib.Path('/proc').glob('[0-9]*/cmdline'):
        try:
            args = p.read_bytes().decode().strip('\0').split('\0')
            if pathlib.Path(args[0]).name == 'kube-apiserver': found.append(args)
        except (OSError, UnicodeError, IndexError): pass
    if found and all(not any('ImagePolicyWebhook' in a for a in args) for args in found): break
    time.sleep(2)
else: raise SystemExit('API server has not entered the intended initial state')
PY
ready=false
for ((i=0;i<90;i++)); do
  if kubectl --request-timeout=5s get --raw=/readyz >/dev/null 2>&1; then ready=true; break; fi
  sleep 2
done
[[ $ready == true ]]
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
