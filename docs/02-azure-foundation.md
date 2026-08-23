# Module 02. AKS NAP 기반 환경 준비

## 목표

Korea Central에 고정 주소 체계의 custom VNet, delegated `cg` subnet, Standard public IP와 NAT Gateway를 만들고, Azure CNI, Standard Load Balancer, user-assigned managed identity, NAP Auto 구성을 사용하는 AKS를 준비합니다. `Standard_D16s_v5` fixed system node는 cluster system Pod와 두 VN2 infrastructure release 전용으로 유지하고, benchmark는 0개 node에서 시작하는 `workshop-nap` NAP benchmark NodePool만 사용합니다.

## 예상 소요 시간

30분

## 시작 전 상태

- Module 01의 preflight가 성공했다.
- `results/environment.json` 이 존재한다.
- 사용할 subscription ID와 Azure location이 확정되었다.
- 아직 workshop 리소스 그룹과 `results/workshop.env` 가 없다.

## 진행 순서

1. 고정 이름, 주소 범위, system/NAP VM 크기와 지원되는 Kubernetes `1.34.x` 버전을 선언합니다.
2. `reserved`, `snet-aks`, `cg` subnet과 `cg`용 NAT Gateway를 만듭니다.
3. AKS용 user-assigned managed identity를 만들고 VNet 범위 `Network Contributor`를 부여합니다.
4. custom VNet에 fixed system node 한 대와 NAP Auto를 사용하는 AKS를 만듭니다.
5. kubelet identity 권한을 부여하고 `workshop-nap` AKSNodeClass/NodePool을 렌더링해 적용합니다.
6. NodePool Ready와 NAP node/NodeClaim 0개를 확인합니다.
7. 성공한 상태를 mode `600`의 `results/workshop.env`에 원자적으로 저장합니다.

### 1) 고정 변수와 지원되는 Kubernetes 1.34 패치 선택

Module 01의 `results/environment.json` 이 이미 `Standard_D16s_v5` 와 `koreacentral` 을 검증했더라도 AKS 생성 직전에 실제 지원 버전을 다시 조회합니다.

```bash
cd ~/aci-vn2-performance-workshop
mkdir -p results

WORKSHOP_STATE="results/workshop.env"

persist_workshop_state() {
  local STATE_TMP
  STATE_TMP="${WORKSHOP_STATE}.tmp.$$"
  (
    umask 077
    {
      printf 'export LOCATION=%q\n' "$LOCATION"
      printf 'export RG=%q\n' "$RG"
      printf 'export VNET=%q\n' "$VNET"
      printf 'export AKS_SUBNET=%q\n' "$AKS_SUBNET"
      printf 'export CG_SUBNET=%q\n' "$CG_SUBNET"
      printf 'export NAT_NAME=%q\n' "$NAT_NAME"
      printf 'export NAT_PIP_NAME=%q\n' "$NAT_PIP_NAME"
      printf 'export AKS=%q\n' "$AKS"
      printf 'export VM_SIZE=%q\n' "$VM_SIZE"
      printf 'export AKS_IDENTITY=%q\n' "$AKS_IDENTITY"
      printf 'export AKS_IDENTITY_ID=%q\n' "$AKS_IDENTITY_ID"
      printf 'export NAP_VM_SIZE=%q\n' "$NAP_VM_SIZE"
      printf 'export NAP_NODEPOOL=%q\n' "$NAP_NODEPOOL"
      printf 'export K8S_VERSION=%q\n' "$K8S_VERSION"
    } >"$STATE_TMP"
  )
  chmod 600 "$STATE_TMP"
  mv "$STATE_TMP" "$WORKSHOP_STATE"
}

( set -euo pipefail
  LOCATION="koreacentral"
  RG="rg-vn2-bench-$RANDOM"
  VNET="vnet-vn2-bench"
  AKS_SUBNET="snet-aks"
  CG_SUBNET="cg"
  NAT_NAME="nat-vn2-bench"
  NAT_PIP_NAME="pip-vn2-bench"
  AKS="aks-vn2-bench"
  AKS_IDENTITY="id-aks-vn2-bench"
  AKS_IDENTITY_ID=""
  VM_SIZE="Standard_D16s_v5"
  NAP_VM_SIZE="Standard_D4s_v5"
  NAP_NODEPOOL="workshop-nap"

  K8S_VERSION="$(az aks get-versions \
    --location "$LOCATION" \
    --query "values[?version=='1.34'].patchVersions | [0]" \
    --output json | jq -r 'if type=="object" then (keys_unsorted | map(select(startswith("1.34."))) | sort_by(split(".")|map(tonumber)) | last // "") else "" end')"
  if ! test -n "$K8S_VERSION"; then
    printf 'No supported Kubernetes 1.34.x version was returned for %s.\n' "$LOCATION" >&2
    exit 1
  fi

  persist_workshop_state
)

source "$WORKSHOP_STATE"
printf 'Using Kubernetes version %s, system VM %s, NAP VM %s\n' \
  "$K8S_VERSION" "$VM_SIZE" "$NAP_VM_SIZE"
```

`NAP_VM_SIZE`는 manifest의 `Standard_D4s_v5`와 일치해야 합니다. 임의의 SKU로 바꾸면 이 워크숍이 측정하려는 고정된 0→1 VM provisioning 경로가 달라집니다. `results/workshop.env is the authoritative workshop state` 이므로 새 Cloud Shell에서는 항상 `source "$WORKSHOP_STATE"`로 복구합니다.

### 2) custom VNet, delegated subnet, NAT Gateway 만들기

```bash
WORKSHOP_STATE="results/workshop.env"
if [[ ! -f "$WORKSHOP_STATE" ]]; then
  printf 'Missing %s. Run step 1 first.\n' "$WORKSHOP_STATE" >&2
  exit 1
fi
source "$WORKSHOP_STATE"

( set -euo pipefail
  az group create -n "$RG" -l "$LOCATION"

  az network public-ip create \
    -g "$RG" \
    -n "$NAT_PIP_NAME" \
    --sku Standard \
    --allocation-method Static

  az network nat gateway create \
    -g "$RG" \
    -n "$NAT_NAME" \
    --public-ip-addresses "$NAT_PIP_NAME"

  az network vnet create -g "$RG" -n "$VNET" \
    --address-prefixes 10.0.0.0/8 \
    --subnet-name reserved \
    --subnet-prefixes 10.0.0.0/24

  az network vnet subnet create -g "$RG" --vnet-name "$VNET" \
    -n "$AKS_SUBNET" \
    --address-prefixes 10.1.0.0/16

  az network vnet subnet create -g "$RG" --vnet-name "$VNET" \
    -n "$CG_SUBNET" \
    --address-prefixes 10.2.0.0/16 \
    --delegations Microsoft.ContainerInstance/containerGroups

  az network vnet subnet update -g "$RG" --vnet-name "$VNET" \
    -n "$CG_SUBNET" \
    --nat-gateway "$NAT_NAME"
)
```

AKS subnet과 ACI `cg` subnet은 분리합니다. `cg`만 `Microsoft.ContainerInstance/containerGroups`에 위임하고 NAT Gateway를 연결합니다.

### 3) AKS용 user-assigned managed identity와 VNet 권한 준비

NAP와 custom VNet을 함께 사용하므로 AKS 생성 전에 identity를 만들고 workshop VNet 전체 범위에 `Network Contributor`를 부여합니다.

```bash
WORKSHOP_STATE="results/workshop.env"

persist_workshop_state() {
  local STATE_TMP
  STATE_TMP="${WORKSHOP_STATE}.tmp.$$"
  (
    umask 077
    {
      printf 'export LOCATION=%q\n' "$LOCATION"
      printf 'export RG=%q\n' "$RG"
      printf 'export VNET=%q\n' "$VNET"
      printf 'export AKS_SUBNET=%q\n' "$AKS_SUBNET"
      printf 'export CG_SUBNET=%q\n' "$CG_SUBNET"
      printf 'export NAT_NAME=%q\n' "$NAT_NAME"
      printf 'export NAT_PIP_NAME=%q\n' "$NAT_PIP_NAME"
      printf 'export AKS=%q\n' "$AKS"
      printf 'export VM_SIZE=%q\n' "$VM_SIZE"
      printf 'export AKS_IDENTITY=%q\n' "$AKS_IDENTITY"
      printf 'export AKS_IDENTITY_ID=%q\n' "$AKS_IDENTITY_ID"
      printf 'export NAP_VM_SIZE=%q\n' "$NAP_VM_SIZE"
      printf 'export NAP_NODEPOOL=%q\n' "$NAP_NODEPOOL"
      printf 'export K8S_VERSION=%q\n' "$K8S_VERSION"
    } >"$STATE_TMP"
  )
  chmod 600 "$STATE_TMP"
  mv "$STATE_TMP" "$WORKSHOP_STATE"
}

source "$WORKSHOP_STATE"

( set -euo pipefail
  az identity create \
    --resource-group "$RG" \
    --name "$AKS_IDENTITY"

  AKS_IDENTITY_ID="$(az identity show \
    --resource-group "$RG" \
    --name "$AKS_IDENTITY" \
    --query id -o tsv)"
  AKS_IDENTITY_PRINCIPAL_ID="$(az identity show \
    --resource-group "$RG" \
    --name "$AKS_IDENTITY" \
    --query principalId -o tsv)"
  VNET_ID="$(az network vnet show \
    --resource-group "$RG" \
    --name "$VNET" \
    --query id -o tsv)"

  if [[ -z "$AKS_IDENTITY_ID" || -z "$AKS_IDENTITY_PRINCIPAL_ID" || -z "$VNET_ID" ]]; then
    printf 'AKS identity or VNet ID could not be resolved.\n' >&2
    exit 1
  fi

  az role assignment create \
    --assignee-object-id "$AKS_IDENTITY_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Network Contributor" \
    --scope "$VNET_ID"

  persist_workshop_state
)

source "$WORKSHOP_STATE"
```

`AKS_IDENTITY_ID`는 identity의 ARM resource ID이고, role assignment의 assignee는 `principalId`입니다. 두 값을 바꾸어 사용하지 않습니다.

### 4) NAP Auto와 fixed D16 system node로 AKS 만들기

```bash
WORKSHOP_STATE="results/workshop.env"
source "$WORKSHOP_STATE"

( set -euo pipefail
  AKS_SUBNET_ID="$(az network vnet subnet show \
    --resource-group "$RG" \
    --vnet-name "$VNET" \
    --name "$AKS_SUBNET" \
    --query id -o tsv)"
  if [[ -z "$AKS_SUBNET_ID" ]]; then
    printf 'AKS subnet ID could not be resolved.\n' >&2
    exit 1
  fi

  az aks create -g "$RG" -n "$AKS" \
    --location "$LOCATION" \
    --nodepool-name system \
    --node-count 1 \
    --node-vm-size "$VM_SIZE" \
    --kubernetes-version "$K8S_VERSION" \
    --network-plugin azure \
    --vnet-subnet-id "$AKS_SUBNET_ID" \
    --service-cidr 172.16.0.0/16 \
    --dns-service-ip 172.16.0.10 \
    --load-balancer-sku standard \
    --node-provisioning-mode Auto \
    --node-provisioning-default-pools None \
    --assign-identity "$AKS_IDENTITY_ID" \
    --generate-ssh-keys
)
```

`--node-provisioning-default-pools None`은 AKS가 기본 NAP NodePool을 만들지 않게 합니다. fixed system node는 `Standard_D16s_v5` 한 대이며 benchmark routing label을 갖지 않습니다. benchmark Pod는 이후 `workshop-nap`만 선택합니다.

### 5) kubelet identity 권한과 kubeconfig 준비

VN2가 workshop RG와 AKS node RG의 리소스를 사용할 수 있도록 kubelet identity에 기존 Contributor 역할을 부여합니다.

```bash
WORKSHOP_STATE="results/workshop.env"
source "$WORKSHOP_STATE"

( set -euo pipefail
  KUBELET_OBJECT_ID="$(az aks show -g "$RG" -n "$AKS" \
    --query identityProfile.kubeletidentity.objectId \
    -o tsv)"
  NODE_RG="$(az aks show -g "$RG" -n "$AKS" --query nodeResourceGroup -o tsv)"
  NODE_RG_ID="$(az group show -n "$NODE_RG" --query id -o tsv)"
  WORKSHOP_RG_ID="$(az group show -n "$RG" --query id -o tsv)"

  if [[ -z "$KUBELET_OBJECT_ID" || -z "$NODE_RG_ID" || -z "$WORKSHOP_RG_ID" ]]; then
    printf 'kubelet identity or resource group ID could not be resolved.\n' >&2
    exit 1
  fi

  az role assignment create \
    --assignee-object-id "$KUBELET_OBJECT_ID" \
    --assignee-principal-type ServicePrincipal \
    --role Contributor \
    --scope "$NODE_RG_ID"

  az role assignment create \
    --assignee-object-id "$KUBELET_OBJECT_ID" \
    --assignee-principal-type ServicePrincipal \
    --role Contributor \
    --scope "$WORKSHOP_RG_ID"

  az aks get-credentials \
    --resource-group "$RG" \
    --name "$AKS" \
    --overwrite-existing

  kubectl get crd \
    aksnodeclasses.karpenter.azure.com \
    nodepools.karpenter.sh \
    nodeclaims.karpenter.sh
)
```

NAP CRD가 없거나 kubelet identity 역할이 실패하면 manifest를 적용하지 말고 해당 실패를 먼저 해결합니다.

### 6) 전용 AKSNodeClass와 NodePool 렌더링, 적용, 검증

template에서 바뀌는 값은 AKS subnet ID 하나뿐입니다.

```bash
WORKSHOP_STATE="results/workshop.env"

persist_workshop_state() {
  local STATE_TMP
  STATE_TMP="${WORKSHOP_STATE}.tmp.$$"
  (
    umask 077
    {
      printf 'export LOCATION=%q\n' "$LOCATION"
      printf 'export RG=%q\n' "$RG"
      printf 'export VNET=%q\n' "$VNET"
      printf 'export AKS_SUBNET=%q\n' "$AKS_SUBNET"
      printf 'export CG_SUBNET=%q\n' "$CG_SUBNET"
      printf 'export NAT_NAME=%q\n' "$NAT_NAME"
      printf 'export NAT_PIP_NAME=%q\n' "$NAT_PIP_NAME"
      printf 'export AKS=%q\n' "$AKS"
      printf 'export VM_SIZE=%q\n' "$VM_SIZE"
      printf 'export AKS_IDENTITY=%q\n' "$AKS_IDENTITY"
      printf 'export AKS_IDENTITY_ID=%q\n' "$AKS_IDENTITY_ID"
      printf 'export NAP_VM_SIZE=%q\n' "$NAP_VM_SIZE"
      printf 'export NAP_NODEPOOL=%q\n' "$NAP_NODEPOOL"
      printf 'export K8S_VERSION=%q\n' "$K8S_VERSION"
    } >"$STATE_TMP"
  )
  chmod 600 "$STATE_TMP"
  mv "$STATE_TMP" "$WORKSHOP_STATE"
}

source "$WORKSHOP_STATE"

( set -euo pipefail
  AKS_SUBNET_ID="$(az network vnet subnet show \
    --resource-group "$RG" \
    --vnet-name "$VNET" \
    --name "$AKS_SUBNET" \
    --query id -o tsv)"
  if [[ -z "$AKS_SUBNET_ID" ]]; then
    printf 'AKS subnet ID could not be resolved for the NAP manifest.\n' >&2
    exit 1
  fi

  sed "s|@@AKS_SUBNET_ID@@|$AKS_SUBNET_ID|g" \
    manifests/nap-workshop-template.yaml \
    > results/nap-workshop.yaml

  if grep -Fq '@@AKS_SUBNET_ID@@' results/nap-workshop.yaml; then
    printf 'NAP manifest rendering left an unresolved subnet token.\n' >&2
    exit 1
  fi

  kubectl apply -f results/nap-workshop.yaml
  kubectl wait --for=condition=Ready nodepool/"$NAP_NODEPOOL" --timeout=10m
  kubectl get nodepool workshop-nap
  kubectl get nodes -l karpenter.sh/nodepool=workshop-nap

  ./scripts/check-nap-capacity.sh \
    --name "$NAP_NODEPOOL" \
    --expect-nodes 0 \
    --expect-nodeclaims 0 \
    --timeout-seconds 1200 \
    --interval-seconds 15

  persist_workshop_state
)

source "$WORKSHOP_STATE"
```

정상 상태는 NodePool Ready이면서 `workshop-nap` node와 NodeClaim이 모두 0개인 상태입니다. 이 단계에서는 benchmark Pod를 만들지 않으므로 D4 VM 비용이 아직 발생하지 않습니다.

## 완료 체크포인트

- `RG`, `VNET`, `AKS_SUBNET`, `CG_SUBNET`, `AKS`, `VM_SIZE`, `K8S_VERSION`이 결정되었다.
- `AKS_IDENTITY`, `AKS_IDENTITY_ID`, `NAP_VM_SIZE`, `NAP_NODEPOOL`이 `results/workshop.env`에 하나씩 저장되었다.
- user-assigned managed identity가 VNet 범위 `Network Contributor`를 받았다.
- AKS가 Azure CNI, Standard Load Balancer, NAP Auto, default pools None으로 생성되었다.
- fixed system node는 `Standard_D16s_v5` 한 대이고 benchmark label이 없다.
- kubelet identity가 node RG와 workshop RG 양쪽에 Contributor 권한을 받았다.
- `AKSNodeClass/workshop-nap`과 `NodePool/workshop-nap`이 적용되고 Ready이다.
- NAP checker가 node 0, NodeClaim 0을 반환했다.
- `results/workshop.env`가 mode `600`이며 fresh Cloud Shell에서 source할 수 있다.

## 문제 해결

### fresh Cloud Shell에서 identity/VNet 권한 재확인

아래 블록은 이전 subshell의 임시 변수에 의존하지 않습니다. 새 shell에서 persisted workshop state를 불러온 뒤 identity principal ID와 VNet ID를 다시 조회합니다.

```bash
cd ~/aci-vn2-performance-workshop
WORKSHOP_STATE="results/workshop.env"
source "$WORKSHOP_STATE"

( set -euo pipefail
  AKS_IDENTITY_PRINCIPAL_ID="$(az identity show \
    --resource-group "$RG" \
    --name "$AKS_IDENTITY" \
    --query principalId -o tsv)"
  VNET_ID="$(az network vnet show \
    --resource-group "$RG" \
    --name "$VNET" \
    --query id -o tsv)"

  if [[ -z "$AKS_IDENTITY_PRINCIPAL_ID" || -z "$VNET_ID" ]]; then
    printf 'AKS identity principal ID or VNet ID could not be resolved.\n' >&2
    exit 1
  fi

  az role assignment list \
    --assignee-object-id "$AKS_IDENTITY_PRINCIPAL_ID" \
    --scope "$VNET_ID" \
    --query "[?roleDefinitionName=='Network Contributor']" \
    --output table
)
```

| 증상 | 확인 명령 | 조치 |
| --- | --- | --- |
| identity role assignment 실패 | `az identity show -g "$RG" -n "$AKS_IDENTITY" --query '{id:id,principalId:principalId}' -o json` | ARM ID와 principal ID를 혼용하지 않았는지 확인하고 VNet scope 역할을 다시 부여 |
| NAP 옵션이 인식되지 않음 | `az version` | Azure CLI 2.76.0 이상으로 갱신하고 Module 01 preflight 재실행 |
| AKS 생성이 network 권한으로 실패 | 위 fresh Cloud Shell 재확인 블록 | cluster 생성 전에 UAMI의 VNet `Network Contributor` 전파를 확인 |
| NAP CRD가 없음 | `kubectl get crd \| grep karpenter` | NAP Auto cluster 생성이 성공했는지 확인하고 임의 CRD를 수동 설치하지 않음 |
| NodePool이 NotReady | `kubectl get nodepool workshop-nap -o yaml` | AKS subnet ID, SKU 요구사항, controller condition을 확인 |
| 초기 node/NodeClaim이 0이 아님 | `kubectl get nodes,nodeclaims -l karpenter.sh/nodepool=workshop-nap` | 남은 workload를 제거하고 consolidation 완료 전 다음 모듈로 진행하지 않음 |

## 이전/다음

- 이전: [Module 01](./01-prerequisites.md)
- 다음: [Module 03](./03-install-dual-vn2.md)
