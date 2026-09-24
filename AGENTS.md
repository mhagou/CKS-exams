# CKS Lab Generator

## Purpose

This repository contains Kubernetes CKS practice exercises.

Every exercise directory contains:

    task.txt

The goal is to generate exactly two main scripts for each exercise:

    setup.sh
    validate.sh

The candidate will later copy/run these scripts on a separate Kubernetes
playground and solve the exercise manually.


## IMPORTANT: generation environment != CKS playground

Codex is running in a development environment.

The Kubernetes playground is NOT the current machine.

Therefore, while generating files, NEVER:

- run kubectl against a real cluster
- SSH to controlplane or node01
- restart kubelet
- restart containerd
- modify systemd
- modify /etc/kubernetes
- install Falco, Trivy, kube-bench, etc. on the current machine
- execute setup.sh
- execute validate.sh
- attempt to prepare the actual lab

Codex's job is to WRITE the scripts, not execute the CKS scenario.

Static checks such as:

    bash -n setup.sh
    bash -n validate.sh

are allowed.


# CKS playground

The generated scripts will later be executed on a Kubernetes playground.

It contains exactly two nodes:

    controlplane
    node01

setup.sh is always launched as root from:

    controlplane

If preparation is required on the worker, setup.sh must perform it remotely
using SSH to:

    node01

Do not require the user to manually prepare node01.

If a task refers to generic worker names such as:

    worker
    worker-node
    cks-worker

adapt the scenario to:

    node01


# Existing exercise files

Before generating scripts:

1. Read task.txt completely.
2. Inspect filenames in the current exercise directory.
3. Read supporting text/YAML/configuration files when relevant.

Existing files may include:

- solution.txt
- pod manifests
- NetworkPolicy manifests
- AppArmor profiles
- Seccomp profiles
- audit policies
- kubeconfigs
- certificates
- archives
- binaries
- tips

Do not modify:

    task.txt
    solution.txt

Do not delete existing exercise resources.


# solution.txt

solution.txt may be consulted to understand the intended exercise.

However:

- setup.sh must never apply the solution
- setup.sh must never print the solution
- validate.sh must validate the objective, not blindly compare against
  solution.txt
- equivalent correct candidate solutions must be accepted


# setup.sh

Generate an executable Bash script named:

    setup.sh

It must start with:

    #!/usr/bin/env bash
    set -Eeuo pipefail

setup.sh prepares the INITIAL state required by task.txt.

It may:

- create Kubernetes resources
- create namespaces
- create Pods, Deployments, Services or ServiceAccounts
- prepare intentionally insecure resources
- modify kubelet configuration
- modify static Pod manifests
- configure controlplane
- SSH to node01
- install required tools
- create required files
- prepare harmless simulations for security exercises

It must be idempotent or safely resettable where practical.


## Dependencies

If the exercise requires a command/tool that may not exist on the playground,
setup.sh must detect this.

When practical, setup.sh must install/download the required tool.

Examples:

- kube-bench
- Falco
- Trivy
- kubesec
- etcdctl
- crictl
- Cilium CLI

Prefer official upstream sources.

When downloading architecture-specific binaries, detect the architecture.

When official checksums are available, verify downloads.


## Do not solve the task

setup.sh must prepare the scenario but MUST NOT solve the exercise.

Do not configure the final secure state requested from the candidate.

Do not reveal the answer in terminal output.

Do not print expected:

- YAML
- securityContext
- NetworkPolicy
- Falco rule
- Seccomp profile
- AppArmor solution
- kubelet flags
- API server flags

unless they are explicitly part of the initial scenario in task.txt.


## setup.sh self-check

At the end, setup.sh must verify that the scenario was successfully prepared.

Use meaningful checks.

If preparation failed:

    exit non-zero

If preparation succeeded, print a concise message such as:

    =================================================
     CKS LAB READY
    =================================================

    Scenario preparation completed successfully.

Do not reveal the solution during this self-check.


# validate.sh

Generate an executable Bash script named:

    validate.sh

validate.sh evaluates the candidate's solution.

It must NEVER repair the candidate's solution.

It must NEVER silently change configuration to make validation pass.

Temporary resources may be created strictly for testing when necessary,
but they must be cleaned up afterwards.


## Validation output

For each objective print:

    [PASS] description

or:

    [FAIL] description

At the end print totals and:

    RESULT: SUCCESS

or:

    RESULT: FAILED

Exit 0 only when all required objectives pass.


# Validation philosophy

Prefer EFFECTIVE STATE and RUNTIME BEHAVIOR over textual matching.

Avoid validators that only grep candidate YAML.

Kubernetes often allows several equivalent correct implementations.

The validator must accept equivalent solutions whenever they satisfy task.txt.


## Avoid false negatives

Unless explicitly required by task.txt, do not require arbitrary:

- volume names
- container names
- ordering
- YAML formatting
- selector representation
- generated resource names

Do not reject a correct solution simply because it differs from an example
solution.


# Runtime validation examples

NetworkPolicy:
- test allowed connectivity
- test denied connectivity
- test required ports

runAsNonRoot:
- inspect the actual UID in the running container when possible

readOnlyRootFilesystem:
- attempt a write to the root filesystem

writable emptyDir:
- attempt a write to the requested mount

ServiceAccount projected token:
- inspect the running container
- verify the required token path

encryption at rest:
- inspect raw etcd data

Falco:
- trigger the requested event
- verify the generated alert

kubelet configuration:
- inspect effective configuration
- verify kubelet service health

systemd:
- inspect actual service state

container runtime:
- prefer crictl for Kubernetes CRI containers


# Lab safety

All scenarios are educational simulations.

Never introduce real:

- malware
- cryptominers
- credential stealing tools
- persistence mechanisms
- destructive payloads

If the task requires a suspicious-looking process, simulate it harmlessly.

For example, a process named cryptominer may simply execute sleep.


# Files Codex may modify

For a normal generation task, modify/create only:

    setup.sh
    validate.sh

Additional files may be generated only when strictly required by the scenario.

Never overwrite:

    task.txt
    solution.txt

Never modify files outside the current exercise directory.


# Final generation checks

Before finishing:

1. Verify setup.sh exists.
2. Verify validate.sh exists.
3. Run:

       bash -n setup.sh
       bash -n validate.sh

4. Ensure both files are executable.
5. Re-read task.txt and verify every task objective is covered.
6. Ensure setup.sh prepares the scenario without solving it.
7. Ensure validate.sh does not produce implementation-specific false negatives.

# Task priority

Some task.txt files may contain an embedded "# Solution" section.

The requirements stated in the question/task are authoritative.

If an embedded solution contains mistakes, outdated commands, typos, or
contradicts the question, follow the question requirements.

Use embedded solutions only as contextual hints.


# Validator complexity

Prefer the simplest robust validator that accurately verifies task.txt.

Do not add complexity merely to support highly hypothetical candidate
implementations.

Support realistic equivalent CKS solutions, but avoid unnecessary abstractions.

Runtime validation is preferred when it provides meaningful additional
confidence.

Do not use Python solely for simple JSON parsing when kubectl JSONPath or jq
can perform the check clearly and robustly.

A validator should be easy for a human to audit and debug.

# Minimal-impact setup

Prefer the smallest possible change that creates the required lab scenario.

Do not reconfigure an entire subsystem when a smaller change is sufficient.

For existing components such as:

- Falco
- kubelet
- containerd
- Kubernetes API server
- Cilium
- systemd services

preserve the existing installation and configuration whenever possible.

Do not move, disable, replace, or rewrite unrelated configuration files.

Do not force a particular runtime driver, engine, plugin, CNI mode, or package
variant unless task.txt requires it or the existing environment makes it
necessary.

Before changing an existing configuration, determine the minimum change needed
for the scenario.

A disposable playground does not justify unnecessary destructive
reconfiguration.


# Sequential lab execution

Assume multiple CKS labs may be executed sequentially on the same playground.

setup.sh should therefore avoid damaging unrelated components or making future
labs unnecessarily dependent on changes from this lab.

Where practical, only reset resources that belong specifically to the current
exercise.


# Dependency minimization

Do not install a dependency merely because it makes script implementation
easier.

Prefer tools normally available on a Kubernetes control plane.

Install additional tools when they are actually required by the exercise or
when robust validation cannot reasonably be performed without them.


# Version robustness

Security tools and Kubernetes components may differ by version.

Avoid hardcoding implementation details that are specific to one version when
they are not required by task.txt.

Inspect the installed environment at setup runtime when necessary and adapt to
it.

Prefer official interfaces and configuration mechanisms over assumptions about
package-specific service names.
