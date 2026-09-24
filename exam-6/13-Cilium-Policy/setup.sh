#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: preparation failed at line $LINENO." >&2' ERR
K=(kubectl --request-timeout=30s)
owner=cks-cilium-policy
[[ $EUID -eq 0 ]] || { echo 'Run setup as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required on controlplane.' >&2; exit 1; }
# Installing/replacing a cluster CNI is not a safe automatic dependency install.
"${K[@]}" get crd ciliumnetworkpolicies.cilium.io >/dev/null || {
    echo 'This lab requires an existing Cilium playground; the CNI was not changed.' >&2
    exit 1
}
[[ -n $("${K[@]}" -n kube-system get pods -l k8s-app=cilium -o name) ]]
"${K[@]}" -n kube-system wait pod -l k8s-app=cilium --for=condition=Ready --timeout=180s

# Refuse collisions before making changes. Only lab-owned namespaces may be reset.
for ns in app data manage; do
    existing=$("${K[@]}" get namespace "$ns" --ignore-not-found -o name)
    if [[ -n $existing ]]; then
        [[ $("${K[@]}" get namespace "$ns" -o jsonpath='{.metadata.labels.cks-lab}') == "$owner" ]] || {
            echo "Namespace $ns already exists and is not owned by this lab; refusing to overwrite it." >&2
            exit 1
        }
    fi
done
for ns in app data manage; do
    if [[ -z $("${K[@]}" get namespace "$ns" --ignore-not-found -o name) ]]; then
        "${K[@]}" create namespace "$ns"
        "${K[@]}" label namespace "$ns" "cks-lab=$owner"
    fi
    # These namespaces are dedicated to this exercise. Reset prior candidate policies.
    "${K[@]}" -n "$ns" delete ciliumnetworkpolicies,networkpolicies --all
    "${K[@]}" -n "$ns" delete pod "${ns}1" --ignore-not-found --wait=true
    "${K[@]}" -n "$ns" run "${ns}1" --image=nginx:stable --labels="id=$ns,cks-lab=$owner"
done
for ns in app data manage; do
    "${K[@]}" -n "$ns" wait pod "${ns}1" --for=condition=Ready --timeout=180s
    "${K[@]}" -n "$ns" exec "${ns}1" -- curl --noproxy '*' -fsS --max-time 5 http://127.0.0.1/ >/dev/null
done
# Establish the initially unrestricted baseline using Pod IPs, independent of DNS.
for ns in data manage; do
    ip=$("${K[@]}" -n "$ns" get pod "${ns}1" -o jsonpath='{.status.podIP}')
    [[ -n $ip ]]
    [[ $ip != *:* ]] || ip="[$ip]"
    "${K[@]}" -n app exec app1 -- curl --noproxy '*' -fsS --retry 5 --retry-all-errors --retry-delay 2 --max-time 5 "http://$ip/" >/dev/null
done
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
