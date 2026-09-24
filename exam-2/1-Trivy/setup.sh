#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground controlplane as root.
STATE=/var/lib/cks-spectacle-trivy
LABEL=cks-lab-spectacle-trivy
fail() { printf 'Setup failed: %s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 ]] || fail 'Run as root on controlplane.'
command -v kubectl >/dev/null || fail 'kubectl is required.'
# Do not inherit scanner filters/configuration from the invoking shell.
for variable in ${!TRIVY_@}; do unset "$variable"; done
umask 077
mkdir -p "$STATE"
rm -f "$STATE/ready"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf '{}\n' > "$work/trivy.yaml"
cd "$work"
if ! command -v trivy >/dev/null; then
    command -v curl >/dev/null || fail 'curl is required to download Trivy.'
    case $(uname -m) in
        x86_64) arch=64bit ;;
        aarch64|arm64) arch=ARM64 ;;
        *) fail 'Unsupported architecture for automatic Trivy installation.' ;;
    esac
    # Resolve the official latest release without adding a JSON dependency.
    url=$(curl -fsSL --retry 3 -o /dev/null -w '%{url_effective}' https://github.com/aquasecurity/trivy/releases/latest)
    version=${url##*/v}
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Cannot resolve Trivy release.'
    archive="trivy_${version}_Linux-${arch}.tar.gz"
    base="https://github.com/aquasecurity/trivy/releases/download/v${version}"
    curl -fsSL --retry 3 "$base/$archive" -o "$archive"
    curl -fsSL --retry 3 "$base/trivy_${version}_checksums.txt" -o checksums.txt
    awk -v file="$archive" '$2 == file {print}' checksums.txt > selected.sha256
    [[ $(wc -l < selected.sha256) == 1 ]] || fail 'Release checksum unavailable.'
    sha256sum -c selected.sha256 >/dev/null
    tar -xzf "$archive" trivy
    install -m 0755 trivy /usr/local/bin/trivy
fi
trivy --version >/dev/null

# Refuse to mix this lab with unrelated workloads in the task's namespace.
if kubectl get namespace spectacle >/dev/null 2>&1; then
    foreign=$(kubectl -n spectacle get pods -l "cks-lab!=$LABEL" -o name)
    [[ -z $foreign ]] || fail 'spectacle contains unrelated pods; use a clean namespace.'
else
    kubectl create namespace spectacle >/dev/null
fi
kubectl -n spectacle delete pod -l "cks-lab=$LABEL" --ignore-not-found --wait=true --timeout=120s >/dev/null

# Old distributions provide genuine vulnerability findings, but only run sleep.
# No controllers recreate pods after the candidate deletes them.
names=(atlas beacon comet delta)
images=(docker.io/library/ubuntu:18.04 docker.io/library/alpine:3.10 docker.io/library/alpine:latest docker.io/library/busybox:stable)
for i in "${!names[@]}"; do
    cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${names[$i]}
  namespace: spectacle
  labels:
    cks-lab: $LABEL
spec:
  nodeSelector:
    kubernetes.io/hostname: node01
  automountServiceAccountToken: false
  containers:
    - name: workload
      image: ${images[$i]}
      imagePullPolicy: Always
      command: ["/bin/sh", "-c", "while :; do sleep 3600; done"]
      resources:
        requests:
          cpu: 5m
          memory: 8Mi
        limits:
          cpu: 100m
          memory: 64Mi
YAML
done
kubectl -n spectacle wait pod -l "cks-lab=$LABEL" --for=condition=Ready --timeout=300s >/dev/null
printf 'Checking scenario images; this may download the vulnerability database.\n'
trivy --config "$work/trivy.yaml" --cache-dir "$STATE/cache" image --download-db-only > "$STATE/database.log" 2>&1 || fail "Database download failed; see $STATE/database.log."
: > "$STATE/baseline.tsv"
critical=0
clean=0
for name in "${names[@]}"; do
    record=$(kubectl -n spectacle get pod "$name" -o jsonpath='{.metadata.uid}{"\t"}{.status.containerStatuses[0].imageID}')
    IFS=$'\t' read -r uid image <<< "$record"
    image=${image#docker-pullable://}
    image=${image#docker://}
    [[ $image == *@sha256:* ]] || fail 'Runtime did not expose a pullable image digest.'
    # Keep the candidate's scans and subsequent restarts on the exact image
    # checked here, even if the upstream tag changes after setup.
    kubectl -n spectacle set image "pod/$name" "workload=$image" >/dev/null
    rc=0
    trivy --config "$work/trivy.yaml" --cache-dir "$STATE/cache" image \
        --image-src remote --scanners vuln --severity CRITICAL --ignorefile /dev/null \
        --ignore-unfixed=false --skip-db-update --exit-code 10 --no-progress \
        "$image" > "$STATE/$name.scan.log" 2>&1 || rc=$?
    case $rc in
        0) classification=clean; clean=$((clean + 1)) ;;
        10) classification=critical; critical=$((critical + 1)) ;;
        *) fail "Image scanning failed; diagnostic logs are in $STATE." ;;
    esac
    printf '%s\t%s\t%s\t%s\n' "$name" "$uid" "$classification" "$image" >> "$STATE/baseline.tsv"
done
(( critical > 0 && clean > 0 )) || fail 'Images no longer provide a mixed scenario with the current database.'
kubectl -n spectacle wait pod -l "cks-lab=$LABEL" --for=condition=Ready --timeout=300s >/dev/null
[[ $(kubectl -n spectacle get pods -o name | wc -l) == 4 ]] || fail 'Unexpected pod count.'
touch "$STATE/ready"
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
