#!/usr/bin/env bash
set -Eeuo pipefail
pass=0 fail=0
ok() { echo "[PASS] $*"; pass=$((pass+1)); }
bad() { echo "[FAIL] $*"; fail=$((fail+1)); }
finish() {
  echo "Totals: $pass passed, $fail failed"
  if ((fail)); then echo 'RESULT: FAILED'; exit 1; fi
  echo 'RESULT: SUCCESS'
}
for cmd in kubectl python3; do
  if ! command -v "$cmd" >/dev/null; then bad "Required tool: $cmd"; finish; fi
done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ns=threat-prevention
if ! kubectl -n "$ns" get networkpolicy -o json > "$work/policies.json" ||
   ! kubectl get pods -A -o json > "$work/pods.json" ||
   ! kubectl get namespaces -o json > "$work/namespaces.json"; then
  bad 'Read live policy and endpoint state'; finish
fi
# Evaluate live API objects, including additive policies. IP/port boundaries
# partition the complete IPv4 address and TCP/UDP/SCTP port spaces, so split
# CIDRs and endPort ranges are accepted without sampling only a few addresses.
if python3 - "$work" > "$work/results" <<'PY'
import ipaddress as ip, json, sys
from pathlib import Path
root=Path(sys.argv[1])
policies=json.loads((root/'policies.json').read_text())['items']
pods=json.loads((root/'pods.json').read_text())['items']
nss={n['metadata']['name']: n['metadata'].get('labels',{}) for n in json.loads((root/'namespaces.json').read_text())['items']}
errors=[]
def check(value, message):
    print(('[PASS] ' if value else '[FAIL] ')+message)
    if not value: errors.append(message)
def matches(sel, labels):
    if any(labels.get(k)!=v for k,v in sel.get('matchLabels',{}).items()): return False
    for e in sel.get('matchExpressions',[]):
        k,op=e['key'],e['operator']; vals=e.get('values',[])
        if op=='In' and labels.get(k) not in vals: return False
        if op=='NotIn' and k in labels and labels[k] in vals: return False
        if op=='Exists' and k not in labels: return False
        if op=='DoesNotExist' and k in labels: return False
    return True
def universal(sel):
    return not sel.get('matchLabels') and not sel.get('matchExpressions')
def types(p):
    s=p['spec']; return s.get('policyTypes', ['Ingress']+(['Egress'] if s.get('egress') else []))
def interval(cidr):
    n=ip.ip_network(cidr)
    return (int(n.network_address),int(n.broadcast_address)+1) if n.version==4 else None
blocked=[interval(c) for c in ('192.168.100.0/24','10.0.99.0/24')]
def malicious(x): return any(a<=x<b for a,b in blocked)
def ranges(peer):
    if not peer: return [(0,2**32)]
    if 'ipBlock' in peer:
        block=peer['ipBlock']; r=interval(block['cidr']); out=[r] if r else []
        for cidr in block.get('except',[]):
            exc=interval(cidr)
            if exc:
                a,b=exc
                out=[part for l,h in out for part in ((l,min(h,a)),(max(l,b),h)) if part[0]<part[1]]
        return out
    out=[]
    for pod in pods:
        m=pod['metadata']; ns=m['namespace']
        if 'namespaceSelector' in peer:
            if not matches(peer['namespaceSelector'], nss.get(ns,{})): continue
        elif ns!='threat-prevention': continue
        if not matches(peer.get('podSelector',{}),m.get('labels',{})): continue
        for addr in pod.get('status',{}).get('podIPs',[]):
            a=ip.ip_address(addr['ip'])
            if a.version==4: out.append((int(a),int(a)+1))
    return out
named=next((p for p in policies if p['metadata']['name']=='block-malicious-egress'),None)
check(named is not None, 'Required policy exists in threat-prevention')
check(bool(named) and universal(named['spec']['podSelector']) and 'Egress' in types(named), 'Named policy covers all present and future pods for egress')
check(all('Ingress' not in types(p) or any(not r.get('from') and not r.get('ports') for r in p['spec'].get('ingress',[])) for p in policies), 'Ingress remains unrestricted')
rules=[]
for p in policies:
    if 'Egress' not in types(p): continue
    for rule in p['spec'].get('egress',[]):
        peers=rule.get('to') or [{}]
        rr=[r for peer in peers for r in ranges(peer)]
        rules.append((p,rule,rr))
# Any selector-scoped extra policy can create an additive hole for selected
# pods. Check every egress grant, including grants to current pod endpoints.
check(not any(malicious(max(a,c)) for _,rule,rr in rules for a,b in rr for c,d in blocked if max(a,c)<min(b,d)), 'Both malicious /24 ranges are denied, including DNS ports, by all egress grants')
# Universal grants must cover every other destination, protocol and port.
# Selector peers cannot cover arbitrary external addresses; ipBlock grants can.
full=[(r,rr) for p,r,rr in rules if universal(p['spec']['podSelector'])]
points={0,2**32}
for a,b in blocked: points.update((a,b))
for _,rr in full:
    for a,b in rr: points.update((a,b))
points=sorted(points)
missing=None
for proto in ('TCP','UDP','SCTP'):
    boundaries={1,65536}
    for r,_ in full:
        for port in r.get('ports',[]):
            if port.get('protocol','TCP')==proto and isinstance(port.get('port'),int):
                boundaries.update((port['port'],port.get('endPort',port['port'])+1))
    for port in sorted(boundaries)[:-1]:
        for addr in points[:-1]:
            if malicious(addr): continue
            def permits(r):
                return not r.get('ports') or any(p.get('protocol','TCP')==proto and ('port' not in p or isinstance(p['port'],int) and p['port']<=port<=p.get('endPort',p['port'])) for p in r['ports'])
            if not any(permits(r) and any(a<=addr<b for a,b in rr) for r,rr in full):
                missing=f'{ip.ip_address(addr)} {proto}/{port}'; break
        if missing: break
    if missing: break
check(missing is None, 'All other IPv4 egress is allowed'+(f' (uncovered: {missing})' if missing else ''))
sys.exit(bool(errors))
PY
then semantic_status=0; else semantic_status=$?; fi
semantic_lines=0
while IFS= read -r line; do
  case "$line" in
    '[PASS] '*) ok "${line#\[PASS\] }"; semantic_lines=$((semantic_lines+1));;
    '[FAIL] '*) bad "${line#\[FAIL\] }"; semantic_lines=$((semantic_lines+1));;
    *) printf '%s\n' "$line";;
  esac
done < "$work/results"
if ((semantic_lines != 5)); then bad 'Policy analysis did not complete'; fi
if ((semantic_status != 0 && fail == 0)); then bad 'Policy analysis failed'; fi
# Runtime probes use the existing lab pods without changing candidate state.
# A timeout to an unowned malicious IP is deliberately NOT treated as proof
# of enforcement. Denial above is checked from the live policy semantics.
if kubectl -n "$ns" exec -i lab-client -- python3 - <<'PY'
import socket,struct
servers=[l.split()[1] for l in open('/etc/resolv.conf') if l.startswith('nameserver')]
assert servers, 'No DNS resolver configured'
name='kubernetes.default.svc.'
# Derive the cluster suffix instead of assuming cluster.local.
for l in open('/etc/resolv.conf'):
    if l.startswith('search'):
        suffix=next((s for s in l.split()[1:] if s.startswith('svc.')),None)
        if suffix: name='kubernetes.default.'+suffix; break
q=struct.pack('!HHHHHH',23456,256,1,0,0,0)+b''.join(bytes([len(s)])+s.encode() for s in name.rstrip('.').split('.'))+b'\0'+struct.pack('!HH',1,1)
def exact(s,n):
    data=b''
    while len(data)<n:
        part=s.recv(n-len(data))
        assert part, 'Short DNS response'
        data+=part
    return data
for kind in (socket.SOCK_DGRAM,socket.SOCK_STREAM):
    success=False
    for server in servers:
        try:
            with socket.socket(socket.AF_INET6 if ':' in server else socket.AF_INET,kind) as s:
                s.settimeout(5); s.connect((server,53))
                if kind==socket.SOCK_STREAM:
                    s.sendall(struct.pack('!H',len(q))+q); reply=exact(s,struct.unpack('!H',exact(s,2))[0])
                else: s.send(q); reply=s.recv(4096)
                ident,flags,_,answers,_,_=struct.unpack('!HHHHHH',reply[:12])
                assert ident==23456 and flags&0x8000 and flags&15==0 and answers>0
                success=True; break
        except (OSError,AssertionError,struct.error): pass
    assert success, 'DNS failed over '+('TCP' if kind==socket.SOCK_STREAM else 'UDP')
PY
then ok 'Runtime DNS over UDP/53 and TCP/53'; else bad 'Runtime DNS over UDP/53 and TCP/53'; fi
for direction in 'lab-client lab-peer' 'lab-peer lab-client'; do
  read -r source destination <<< "$direction"
  if address=$(kubectl -n "$ns" get pod "$destination" -o jsonpath='{.status.podIP}') &&
     kubectl -n "$ns" exec "$source" -- python3 -c \
       'import sys,urllib.request; host=sys.argv[1]; host="["+host+"]" if ":" in host else host; assert urllib.request.urlopen("http://"+host+":8080",timeout=5).status==200' "$address"; then
    ok "Runtime allowed TCP egress and ingress: $source to $destination"
  else bad "Runtime allowed TCP egress and ingress: $source to $destination"; fi
done
echo 'Note: blocked external CIDRs are checked semantically; this does not certify CNI packet enforcement.'
finish
