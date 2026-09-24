#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the disposable playground's controlplane as root.
manifest=/etc/kubernetes/manifests/kube-apiserver.yaml
admin=/etc/kubernetes/admin.conf
state=/var/lib/cks-authorization
work=''
trap '[[ -z "$work" ]] || rm -rf "$work"' EXIT
trap 'echo "Scenario preparation failed; review the error above. Original files are retained in /var/lib/cks-authorization." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
for tool in kubectl awk curl mktemp; do
    command -v "$tool" >/dev/null || { echo "Required playground command missing: $tool" >&2; exit 1; }
done
[[ -s "$manifest" && -s "$admin" ]]
k() { kubectl --kubeconfig="$admin" --request-timeout=10s "$@"; }
k get --raw=/readyz >/dev/null

# Deliberately restrict editing to the normal kubeadm block-list format.
# Do not discard structured authentication/authorization configuration from other labs.
awk '
/--(authentication-config|authorization-config|admission-control)=/ { bad=1 }
/^[[:space:]]*- kube-apiserver[[:space:]]*$/ { commands++ }
/--(anonymous-auth|authorization-mode|enable-admission-plugins|disable-admission-plugins)/ {
    if ($0 !~ /^[[:space:]]*- --(anonymous-auth|authorization-mode|enable-admission-plugins|disable-admission-plugins)=[A-Za-z0-9,]*[[:space:]]*$/) bad=1
}
END { exit (bad || commands != 1) }
' "$manifest" || { echo 'Unsupported API server manifest layout or conflicting configuration; no changes made.' >&2; exit 1; }

install -d -m 700 "$state"
work=$(mktemp -d "$state/work.XXXXXX")
[[ -e "$state/kube-apiserver.yaml.original" ]] || cp -p "$manifest" "$state/kube-apiserver.yaml.original"
install -d -m 700 /root/.kube
if [[ -e /root/.kube/config && ! -e "$state/root-kubeconfig.original" ]]; then
    cp -p /root/.kube/config "$state/root-kubeconfig.original"
fi

# Preserve cluster endpoint and trust information, but remove every credential.
k config view --minify --flatten --raw > "$work/anonymous.conf"
chmod 600 "$work/anonymous.conf"
kubectl --kubeconfig="$work/anonymous.conf" config unset users >/dev/null
context=$(kubectl --kubeconfig="$work/anonymous.conf" config current-context)
kubectl --kubeconfig="$work/anonymous.conf" config set-context "$context" --user=cks-anonymous >/dev/null

# This named binding is an exercise resource; reset its immutable roleRef as needed.
k delete clusterrolebinding system:anonymous --ignore-not-found >/dev/null
k create clusterrolebinding system:anonymous --clusterrole=cluster-admin --user=system:anonymous >/dev/null

# Keep unrelated options and admission plugins. Only reset the exercise settings.
awk '
function plugins(line,    value,n,a,i,result) {
    value=line; sub(/^.*=/,"",value); gsub(/[[:space:]]/,"",value)
    n=split(value,a,","); result=""
    for(i=1;i<=n;i++) if(a[i]!="NodeRestriction" && a[i]!="") result=result (result==""?"":",") a[i]
    return result
}
/^[[:space:]]*- kube-apiserver[[:space:]]*$/ {
    print; indent=$0; sub(/-.*/,"",indent)
    print indent "- --anonymous-auth=true"
    print indent "- --authorization-mode=AlwaysAllow"
    next
}
/^[[:space:]]*- --(anonymous-auth|authorization-mode)=/ { next }
/^[[:space:]]*- --enable-admission-plugins=/ {
    value=plugins($0); if(value!="") { sub(/=.*/,"=" value); print }; next
}
{ print }
' "$manifest" > "$work/kube-apiserver.yaml"
# Stage outside the watched manifests directory, then rename atomically.
cp -p "$manifest" "$work/staged.yaml"
cat "$work/kube-apiserver.yaml" > "$work/staged.yaml"
mv "$work/staged.yaml" "$manifest"

server=$(kubectl --kubeconfig="$work/anonymous.conf" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
ready=false
for ((attempt=0; attempt<90; attempt++)); do
    # /api/v1/nodes also exercises authorization, unlike public discovery endpoints.
    code=$(curl --noproxy '*' -ksS --max-time 5 -o /dev/null -w '%{http_code}' "${server%/}/api/v1/nodes" 2>/dev/null) || code=000
    if [[ "$code" == 200 ]] && k get --raw=/readyz >/dev/null 2>&1; then
        # Confirm kubelet has started the process with the prepared arguments.
        if awk 'BEGIN { RS="\0" } $0=="--authorization-mode=AlwaysAllow" { found=1 } END { exit !found }' /proc/[0-9]*/cmdline 2>/dev/null; then
            ready=true; break
        fi
    fi
    sleep 2
done
[[ "$ready" == true ]] || { echo 'API server did not reach the prepared initial state.' >&2; exit 1; }
install -m 600 "$work/anonymous.conf" /root/.kube/config
kubectl --kubeconfig=/root/.kube/config --request-timeout=10s get nodes >/dev/null
[[ $(k get clusterrolebinding system:anonymous -o jsonpath='{.roleRef.name}') == cluster-admin ]]
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\nInitial kubectl configuration: /root/.kube/config\n'
if [[ -n ${KUBECONFIG:-} && "$KUBECONFIG" != /root/.kube/config ]]; then
    echo 'Your shell overrides the default kubeconfig; use the initial configuration path above for this exercise.'
fi
