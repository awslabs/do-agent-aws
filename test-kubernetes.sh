#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Host-side test of the kubernetes target's manifests (run by test.sh): run.sh's own generate_kubernetes_manifests renders
# into ./scratch/test-kubernetes (gitignored); no kubectl runs. Each check FAILS if the property is removed:
#   1. by default the Ingress (plain HTTP, no authentication in front) and the HorizontalPodAutoscaler are not rendered,
#      and a copy an earlier render left is removed, so `kubectl apply -f` of the folder creates neither
#   2. KUBERNETES_INGRESS=true and KUBERNETES_HPA=true render each (CONTROL: check 1 can tell)
#   3. the pod runs as the unprivileged user: runAsNonRoot, uid 1000, the RuntimeDefault seccomp profile, no privilege
#      escalation and no capability

source .env > /dev/null 2>&1
D=./scratch/test-kubernetes
fail() { echo "Test-kubernetes FAILED: $*"; exit 1; }
eval "$(sed -n '/^function generate_kubernetes_manifests/,/^}/p' run.sh)"
declare -F generate_kubernetes_manifests > /dev/null || fail "run.sh has no generate_kubernetes_manifests"
render()
{
	# render <ingress> <hpa> - the manifests of one render, by name
	KUBERNETES_APP_PATH=${D} KUBERNETES_INGRESS=$1 KUBERNETES_HPA=$2 DRY_RUN=false VERBOSE=false generate_kubernetes_manifests > /dev/null
	(cd "${D}" && ls ./*.yaml | sed 's#^\./##' | tr '\n' ' ')
}
rm -rf "${D:?}" && mkdir -p "${D}" || fail "cannot create ${D}"
echo "kind: Ingress" > "${D}/050-ingress.yaml"   # an earlier render's copy
GOT=$(render false false)
[ "${GOT}" == "010-namespace.yaml 020-deployment.yaml 030-service.yaml " ] || fail "1: the default render is: ${GOT}"
echo "ok 1 - by default neither the Ingress nor the HorizontalPodAutoscaler is rendered, and an earlier copy is removed"
GOT=$(render true true)
case "${GOT}" in *"040-hpa.yaml"*"050-ingress.yaml"*) ;; *) fail "2: KUBERNETES_INGRESS=true KUBERNETES_HPA=true rendered: ${GOT}" ;; esac
grep -q "kind: Ingress" "${D}/050-ingress.yaml" && grep -q "kind: HorizontalPodAutoscaler" "${D}/040-hpa.yaml" || fail "2: the opted-in manifests are not the templates'"
echo "ok 2 - KUBERNETES_INGRESS=true and KUBERNETES_HPA=true render each"
for W in "runAsNonRoot: true" "runAsUser: 1000" "type: RuntimeDefault" "allowPrivilegeEscalation: false" 'drop: ["ALL"]'; do
	grep -qF "${W}" "${D}/020-deployment.yaml" || fail "3: the deployment does not carry '${W}'"
done
echo "ok 3 - the pod runs as uid 1000 with runAsNonRoot, the RuntimeDefault seccomp profile, no privilege escalation and no capability"
rm -rf "${D:?}"
echo "Test-kubernetes succeeded"
