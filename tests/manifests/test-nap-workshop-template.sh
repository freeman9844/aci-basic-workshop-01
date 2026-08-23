#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$ROOT/.test-nap-workshop-template"
MANIFEST="$ROOT/manifests/nap-workshop-template.yaml"
RENDERED="$TEST_DIR/rendered.yaml"
SUBNET_ID="/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/aks"

cleanup() {
  rm -rf "$TEST_DIR"
}

trap cleanup EXIT
cleanup
mkdir -p "$TEST_DIR"

if [[ ! -f "$MANIFEST" ]]; then
  printf 'Missing required manifest: manifests/nap-workshop-template.yaml\n' >&2
  exit 1
fi

sed "s|@@AKS_SUBNET_ID@@|$SUBNET_ID|g" "$MANIFEST" >"$RENDERED"

required_strings=(
  "apiVersion: karpenter.azure.com/v1beta1"
  "kind: AKSNodeClass"
  "name: workshop-nap"
  "vnetSubnetID: \"$SUBNET_ID\""
  "apiVersion: karpenter.sh/v1"
  "kind: NodePool"
  "cpu: \"4\""
  "consolidationPolicy: WhenEmpty"
  "consolidateAfter: 30s"
  "benchmark-path: aks-nap"
  "group: karpenter.azure.com"
  "kind: AKSNodeClass"
  "name: workshop-nap"
  "key: benchmark-path"
  "value: aks-nap"
  "effect: NoSchedule"
  "key: karpenter.azure.com/sku-name"
  "values: [Standard_D4s_v5]"
  "key: karpenter.sh/capacity-type"
  "values: [on-demand]"
  "key: kubernetes.io/os"
  "values: [linux]"
  "key: kubernetes.io/arch"
  "values: [amd64]"
)

for item in "${required_strings[@]}"; do
  if ! grep -Fq -- "$item" "$RENDERED"; then
    printf 'Rendered NAP manifest is missing required text: %s\n' "$item" >&2
    exit 1
  fi
done

if grep -Fq '@@AKS_SUBNET_ID@@' "$RENDERED"; then
  printf 'Rendered NAP manifest still contains the subnet token\n' >&2
  exit 1
fi

if [[ "$(grep -c '^kind: AKSNodeClass$' "$RENDERED")" -ne 1 ]]; then
  printf 'Rendered NAP manifest must contain exactly one AKSNodeClass\n' >&2
  exit 1
fi

if [[ "$(grep -c '^kind: NodePool$' "$RENDERED")" -ne 1 ]]; then
  printf 'Rendered NAP manifest must contain exactly one NodePool\n' >&2
  exit 1
fi

printf 'PASS: NAP workshop template manifest contract\n'
