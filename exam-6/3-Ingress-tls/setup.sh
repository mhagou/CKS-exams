#!/usr/bin/env bash
set -Eeuo pipefail

kubectl() { command kubectl --request-timeout=20s "$@"; }

# Generate prerequisites only. Candidate deployments, Secret and Ingress are absent.
# task.txt omits deployment names: prepared Services select app=asia/app=europe.
# A world/europe ExternalName Service bridges the namespace boundary required by
# the task's Ingress. No /asia route is requested.
LAB_DIR=${LAB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
OWNER=cks-ingress-tls
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID == 0 ]] || { echo 'Run on controlplane as root.' >&2; exit 1; }
type -P kubectl >/dev/null || { echo 'kubectl and an administrator kubeconfig are required.' >&2; exit 1; }
missing=()
for tool in jq openssl curl; do
    command -v "$tool" >/dev/null || missing+=("$tool")
done
if ((${#missing[@]})); then
    command -v apt-get >/dev/null || { echo "Install required commands: ${missing[*]}" >&2; exit 1; }
    apt-get update -qq
    apt-get install -y "${missing[@]}"
fi
kubectl get node controlplane node01 >/dev/null

# Refuse to overwrite other labs or an already-started attempt.
for ns in asia europe world; do
    if kubectl get namespace "$ns" -o json > /dev/null 2>&1; then
        [[ $(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.cks-lab}') == "$OWNER" ]] || {
            echo "Namespace $ns already exists and is not owned by this lab." >&2; exit 1;
        }
    fi
done
for ns in asia europe; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        [[ $(kubectl -n "$ns" get deployments -o json | jq '.items | length') == 0 ]] || {
            echo 'An attempt already exists; setup will not overwrite candidate work.' >&2; exit 1;
        }
    fi
done
if kubectl get namespace world >/dev/null 2>&1; then
    [[ -z $(kubectl -n world get ingress world --ignore-not-found -o name) &&
       -z $(kubectl -n world get secret test-secret --ignore-not-found -o name) ]] || {
        echo 'An attempt already exists; setup will not overwrite candidate work.' >&2; exit 1;
    }
fi

# Reuse an existing community ingress-nginx controller without changing its settings.
# Official historical controller is needed for the annotation in this exercise.
# Upstream installation reference: https://kubernetes.github.io/ingress-nginx/deploy/
classes=$(kubectl get ingressclasses -o json)
if ! jq -e '.items[] | select(.spec.controller == "k8s.io/ingress-nginx")' <<<"$classes" >/dev/null; then
    if kubectl get namespace ingress-nginx >/dev/null 2>&1; then
        echo 'An existing ingress-nginx installation needs attention; refusing to replace it.' >&2
        exit 1
    fi
    manifest=$(mktemp)
    trap 'rm -f "${manifest:-}"' EXIT
    curl -fsSL --retry 3 https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/baremetal/deploy.yaml -o "$manifest"
    kubectl apply -f "$manifest" >/dev/null
    # Only the newly installed controller: support the task's classless Ingress.
    kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type=json \
        -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--watch-ingress-without-class=true"}]' >/dev/null
    kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=240s >/dev/null
fi
kubectl get pods -A -o json | jq -e '
    .items[] | select(any(.spec.containers[]; .image | test("ingress-nginx/controller"))) |
    select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
' >/dev/null || { echo 'No ready ingress-nginx controller found.' >&2; exit 1; }

for ns in asia europe world; do
    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
        kubectl create namespace "$ns" >/dev/null
        kubectl label namespace "$ns" "cks-lab=$OWNER" >/dev/null
    fi
done
for ns in asia europe; do
    if [[ -z $(kubectl -n "$ns" get service "$ns" --ignore-not-found -o name) ]]; then
        kubectl -n "$ns" create service clusterip "$ns" --tcp=80:80 >/dev/null
    fi
    kubectl -n "$ns" get service "$ns" -o json | jq -e --arg app "$ns" '
        .spec.selector.app == $app and any(.spec.ports[]; .port == 80 and .targetPort == 80)
    ' >/dev/null
done
if [[ -z $(kubectl -n world get service europe --ignore-not-found -o name) ]]; then
    kubectl -n world create service externalname europe --external-name=europe.europe.svc.cluster.local --tcp=80:80 >/dev/null
fi
kubectl -n world get service europe -o json | jq -e '
    .spec.type == "ExternalName" and .spec.externalName == "europe.europe.svc.cluster.local" and
    any(.spec.ports[]; .port == 80)
' >/dev/null

mkdir -p "$LAB_DIR"
if [[ ! -e $LAB_DIR/cert.crt && ! -e $LAB_DIR/cert.key ]]; then
    (umask 077; openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
        -subj '/CN=world.universe.mine' -addext 'subjectAltName=DNS:world.universe.mine' \
        -keyout "$LAB_DIR/cert.key" -out "$LAB_DIR/cert.crt" 2>/dev/null)
fi
openssl x509 -in "$LAB_DIR/cert.crt" -checkend 3600 -noout >/dev/null
openssl x509 -in "$LAB_DIR/cert.crt" -checkhost world.universe.mine -noout >/dev/null
cert_pub=$(openssl x509 -in "$LAB_DIR/cert.crt" -pubkey -noout)
key_pub=$(openssl pkey -in "$LAB_DIR/cert.key" -pubout 2>/dev/null)
[[ $cert_pub == "$key_pub" ]]
[[ -z $(kubectl -n world get ingress world --ignore-not-found -o name) ]]
[[ -z $(kubectl -n world get secret test-secret --ignore-not-found -o name) ]]
for ns in asia europe; do
    [[ $(kubectl -n "$ns" get deployments -o json | jq '.items | length') == 0 ]]
done
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
printf 'Certificate input files: %s/cert.crt and %s/cert.key\n' "$LAB_DIR" "$LAB_DIR"
printf 'Prepared Services in asia and europe select app=asia and app=europe respectively.\n'
printf 'Available Ingress classes: '
kubectl get ingressclasses -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}{"\n"}'
