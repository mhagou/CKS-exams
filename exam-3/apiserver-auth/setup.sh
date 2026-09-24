#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the disposable playground's controlplane, never during generation.
die() { printf 'Setup failed: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run as root on controlplane.'
for tool in curl python3; do
    command -v "$tool" >/dev/null || die "Required command is missing: $tool"
done

manifest=/etc/kubernetes/manifests/kube-apiserver.yaml
if [[ -f $manifest ]]; then
    mode=kubeadm
    command -v kubectl >/dev/null || die 'kubectl is required.'
    kc=(kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=10s)
elif command -v k3s >/dev/null && systemctl is-active --quiet k3s; then
    mode=k3s
    kc=(k3s kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml --request-timeout=10s)
else
    die 'Expected a kubeadm static API server or an active k3s server service.'
fi
"${kc[@]}" get --raw=/readyz >/dev/null 2>&1 || die 'The API server must be healthy before setup.'
endpoint=$("${kc[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
[[ $endpoint == https://* ]] || die 'Expected an HTTPS API endpoint.'
endpoint=${endpoint%/}

anonymous_enabled() {
    local code
    code=$(curl --disable --noproxy '*' -ksS --connect-timeout 3 --max-time 8 \
        -o /dev/null -w '%{http_code}' "$endpoint/api" 2>/dev/null) || return 1
    # 403 means an anonymous identity was authenticated but not authorized.
    [[ $code == 200 || $code == 403 ]]
}

work=$(mktemp -d)
changed=0
finish() {
    local status=$?
    local restore_failed=0 stage
    trap - EXIT
    if (( status != 0 && changed )); then
        printf 'Preparation failed; restoring the configuration changed by setup.\n' >&2
        while IFS= read -r path; do
            if stage=$(mktemp "$(dirname "$path")/.cks-apiserver-auth.XXXXXX") &&
                cp -p -- "$work/backup$path" "$stage" && mv -f -- "$stage" "$path"; then
                :
            else
                restore_failed=1
            fi
        done < "$work/changed"
        if [[ $mode == k3s ]]; then
            systemctl daemon-reload || true
            systemctl restart k3s || true
        fi
    fi
    if (( restore_failed )); then
        printf 'A backup could not be restored. Backups retained in %s\n' "$work" >&2
    else
        rm -rf -- "$work"
    fi
    exit "$status"
}
trap finish EXIT

if ! anonymous_enabled; then
    if [[ $mode == kubeadm ]]; then
        printf '%s\n' "$manifest" > "$work/sources"
    else
        # Read the actual unit's sources, including installer environment files.
        systemctl show k3s -p FragmentPath --value > "$work/sources"
        systemctl show k3s -p DropInPaths --value | tr ' ' '\n' >> "$work/sources"
        systemctl show k3s -p EnvironmentFiles --value > "$work/envfiles"
        pid=$(systemctl show k3s -p MainPID --value)
        python3 - "$pid" "$work/envfiles" >> "$work/sources" <<'PY'
import glob, pathlib, re, sys
pid, envfile = sys.argv[1:]
args = pathlib.Path(f'/proc/{pid}/cmdline').read_bytes().decode().split('\0')
env = pathlib.Path(f'/proc/{pid}/environ').read_bytes().decode().split('\0')
config = next((s.split('=', 1)[1] for s in env if s.startswith('K3S_CONFIG_FILE=')),
              '/etc/rancher/k3s/config.yaml')
for i, arg in enumerate(args):
    if arg in ('--config', '-c') and i + 1 < len(args):
        config = args[i + 1]
    elif arg.startswith('--config='):
        config = arg.split('=', 1)[1]
print(config)
for path in sorted(glob.glob(config + '.d/*.yaml')):
    print(path)
for path in re.findall(r'(\S+)\s+\(ignore_errors=(?:yes|no)\)', pathlib.Path(envfile).read_text()):
    print(path)
PY
    fi

    # A surgical text edit preserves comments, ordering, and unrelated settings.
    # Nonstandard/structured authentication configurations are left untouched.
    python3 - "$mode" "$work" <<'PY'
import pathlib, re, shutil, sys
mode, work = sys.argv[1], pathlib.Path(sys.argv[2])
edits = []
for name in dict.fromkeys(work.joinpath('sources').read_text().splitlines()):
    path = pathlib.Path(name).resolve()
    if not name or not path.is_file():
        continue
    old = path.read_text()
    if mode == 'kubeadm':
        # Standard kubeadm scalar list arguments, including quoted scalars.
        pattern = r'(?m)^(\s*-\s*[\"\x27]?--anonymous-auth=)false([\"\x27]?\s*(?:#.*)?)$'
    else:
        # K3s YAML, systemd ExecStart arguments, and EnvironmentFile values.
        pattern = r'(?m)^(?!\s*#)([^\n]*?\banonymous-auth=)false(?=[\s\"\x27,\]\\]|$)'
    new = re.sub(pattern, lambda m: m[0].replace('anonymous-auth=false', 'anonymous-auth=true'), old)
    if new != old:
        edits.append((path, new))
if not edits:
    sys.exit('No supported explicit setting was found to reset. No configuration was changed; '
             'inspect custom authentication configuration or a custom service launch method.')
for path, new in edits:
    backup = work / 'backup' / str(path).lstrip('/')
    backup.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, backup)
    stage = work / 'stage' / str(path).lstrip('/')
    stage.parent.mkdir(parents=True, exist_ok=True)
    stage.write_text(new)
work.joinpath('changed').write_text(''.join(str(p) + '\n' for p, _ in edits))
PY
    changed=1
    while IFS= read -r path; do
        # Stage a hidden sibling, then rename: kubelet never sees a partial YAML.
        stage=$(mktemp "$(dirname "$path")/.cks-apiserver-auth.XXXXXX")
        cp -p -- "$path" "$stage"
        cat "$work/stage$path" > "$stage"
        mv -f -- "$stage" "$path"
    done < "$work/changed"
    if [[ $mode == k3s ]]; then
        systemctl daemon-reload
        systemctl restart k3s
    fi
fi

# Require several consecutive good observations after the configuration reload.
good=0
for ((attempt=0; attempt<60; attempt++)); do
    if "${kc[@]}" get --raw=/readyz >/dev/null 2>&1 && anonymous_enabled; then
        good=$((good + 1))
        (( good >= 3 )) && break
    else
        good=0
    fi
    sleep 5
done
(( good >= 3 )) || die 'The initial scenario did not become healthy and observable.'
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
