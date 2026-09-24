#!/usr/bin/env bash
set -Eeuo pipefail
# Run only on the disposable playground's controlplane, as root.
# Package installation follows https://falco.org/docs/setup/packages/.
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null
kubectl get node controlplane >/dev/null
command -v apt-get >/dev/null || { echo 'This setup requires Debian/Ubuntu.' >&2; exit 1; }
case $(dpkg --print-architecture) in
  amd64|arm64) ;;
  *) echo 'Unsupported Falco package architecture.' >&2; exit 1 ;;
esac
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y ca-certificates curl gnupg jq python3-yaml util-linux
if ! command -v falco >/dev/null; then
  curl -fsSL https://falco.org/repo/falcosecurity-packages.asc |
    gpg --batch --yes --dearmor -o /usr/share/keyrings/falco-archive-keyring.gpg
  echo 'deb [signed-by=/usr/share/keyrings/falco-archive-keyring.gpg] https://download.falco.org/packages/deb stable main' > /etc/apt/sources.list.d/falcosecurity.list
  apt-get update -qq
  # APT verifies signed repository metadata and package hashes; selects host architecture.
  FALCO_FRONTEND=noninteractive FALCO_DRIVER_CHOICE=modern_ebpf FALCOCTL_ENABLED=no apt-get install -y falco
fi
[[ -f /etc/falco/falco.yaml && -f /etc/falco/falco_rules.yaml ]]
# Preserve the original configuration/rules once, then reset only this lab's state.
backup=/var/lib/cks-falco-lab
mkdir -p "$backup"
if [[ ! -d $backup/original ]]; then
  cp -a /etc/falco "$backup/original"
fi
systemctl stop falco.service || true
systemctl disable --now falcoctl-artifact-follow.service 2>/dev/null || true
python3 - "$backup/original" <<'PY'
import pathlib, sys, yaml
original = pathlib.Path(sys.argv[1])
config = yaml.safe_load((original / 'falco.yaml').read_text())
# Retain upstream plugin configuration, including container metadata enrichment.
config.update(rules_files=['/etc/falco/falco_rules.yaml',
                           '/etc/falco/falco_rules.local.yaml', '/etc/falco/rules.d'],
              json_output=True, json_include_output_property=True,
              buffered_outputs=False, priority='debug',
              file_output={'enabled': True, 'keep_alive': False,
                           'filename': '/var/log/falco-cks.json'},
              stdout_output={'enabled': True},
              engine={'kind': 'modern_ebpf'})
# Avoid unrelated output additions/config overrides masking the exercise.
config['config_files'] = []
config['append_output'] = []
if any(p.get('name') == 'container' for p in config.get('plugins', [])):
    config['load_plugins'] = ['container']
rules = yaml.safe_load((original / 'falco_rules.yaml').read_text())
found = False
for rule in rules:
    if rule.get('rule') == 'Terminal shell in container':
        rule['output'] = 'A terminal shell was opened (container=%container.id command=%proc.cmdline)'
        rule['enabled'] = True
        found = True
if not found:
    raise SystemExit('Upstream terminal-shell rule missing; cannot prepare this exercise.')
pathlib.Path('/etc/falco/falco.yaml').write_text(yaml.safe_dump(config, sort_keys=False))
pathlib.Path('/etc/falco/falco_rules.yaml').write_text(yaml.safe_dump(rules, sort_keys=False))
pathlib.Path('/etc/falco/falco_rules.local.yaml').write_text('# Local rule customizations\n')
PY
# The lab owns these paths; preserve pre-existing rule fragments outside the load path.
if [[ -d /etc/falco/rules.d ]]; then
  mv /etc/falco/rules.d "$backup/rules.d.$(date +%s%N)"
fi
mkdir -p /etc/falco/rules.d
systemctl enable falco-modern-bpf.service
systemctl restart falco.service
systemctl is-active --quiet falco.service
kubectl create namespace space --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n space delete pod shell-lab --ignore-not-found --wait=true >/dev/null
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: shell-lab
  namespace: space
  labels:
    cks-exercise: falco
spec:
  nodeName: controlplane
  tolerations:
    - operator: Exists
  containers:
    - name: workload
      image: docker.io/library/busybox:1.37.0
      command: ["sleep", "infinity"]
      securityContext:
        runAsUser: 1000
        allowPrivilegeEscalation: false
  restartPolicy: Always
YAML
kubectl -n space wait --for=condition=Ready pod/shell-lab --timeout=180s >/dev/null
cid=$(kubectl -n space get pod shell-lab -o jsonpath='{.status.containerStatuses[0].containerID}')
cid=${cid#*://}
[[ -n $cid ]]
# script(1) supplies a real local PTY so kubectl -t works even from automation.
# Only read bytes appended after the baseline: old alerts cannot satisfy self-check.
log=/var/log/falco-cks.json
touch "$log"
offset=$(stat -c %s "$log")
ready=false
for attempt in {1..12}; do
  script -q -e -c 'kubectl -n space exec -it shell-lab -- /bin/sh -c "sleep 1"' /dev/null >/dev/null
  sleep 2
  if tail -c +"$((offset + 1))" "$log" | jq -e -s --arg cid "$cid" '
      any(.[]; .rule == "Terminal shell in container" and
        ((.output_fields["container.id"] // "") as $id |
        ($id | length) >= 12 and ($cid | startswith($id))))' >/dev/null; then
    ready=true
    break
  fi
done
[[ $ready == true ]] || { echo 'Fresh shell alert missing; inspect Falco service logs.' >&2; exit 1; }
systemctl is-active --quiet falco.service
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\nPod: space/shell-lab on controlplane\nFalco alerts: /var/log/falco-cks.json\n'
