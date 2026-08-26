# 02. AKS NAP 기반 환경 준비

> Korea Central에 custom VNet, NAT Gateway, user-assigned managed identity, NAP Auto AKS를 만들고 `results/workshop.env`를 기준 상태로 저장합니다.


## 목표

이 모듈을 완료하면 다음을 할 수 있습니다.

- 고정 주소 체계의 custom VNet, delegated `cg` subnet, Standard public IP, NAT Gateway를 같은 순서로 준비할 수 있습니다.
- `AKS_IDENTITY` 와 VNet 범위 `Network Contributor` 권한을 연결해 NAP Auto용 AKS를 만들 수 있습니다.
- Azure CNI, Standard Load Balancer, user-assigned managed identity, NAP Auto 구성을 사용하는 AKS를 같은 계약으로 준비할 수 있습니다.
- `az aks show` 와 `kubectl get nodes -o wide` 로 NAP Auto 활성화와 fixed system node 상태를 검증할 수 있습니다.
- `results/workshop.env` 를 mode `600`으로 원자적으로 저장해 다음 모듈의 기준 상태로 재사용할 수 있습니다.

## 예상 소요 시간

30분

## 시작 전 상태

- Module 01의 preflight가 성공했다.
- `results/environment.json` 이 존재한다.
- 사용할 subscription ID와 Azure location이 확정되었다.
- 아직 workshop 리소스 그룹과 `results/workshop.env` 가 없다.


## 태그 범례

| 태그 | 의미 |
|------|------|
| 🟢 **실행** | 참가자가 직접 입력하거나 수행해야 하는 단계 |
| 👁️ **설명** | 왜 이 단계를 하는지 이해하기 위한 읽기 전용 안내 |
| 📋 **예상 출력** | 실행 결과와 비교할 기준 출력 |
| ⚠️ **주의** | 비용, 순서, 안전성, 계약 조건 안내 |


## 진행 순서

1. 고정 이름, 주소 범위, system VM 크기와 지원되는 Kubernetes `1.34.x` 버전을 선언합니다.
2. `reserved`, `snet-aks`, `cg` subnet과 `cg`용 NAT Gateway를 만듭니다.
3. AKS용 user-assigned managed identity를 만들고 VNet 범위 `Network Contributor`를 부여합니다.
4. custom VNet에 fixed system node 한 대와 NAP Auto를 사용하는 AKS를 만듭니다.
5. kubelet identity 권한을 부여하고 kubeconfig를 가져온 뒤, NAP mode와 node 상태만 확인합니다.
6. 성공한 상태를 mode `600`의 `results/workshop.env`로 계속 복구할 수 있게 유지합니다.


👁️ **설명**

아래 단계는 설명 → 실행 → 예상 출력 → 주의 순서로 읽습니다. 코드 블록은 순서를 바꾸지 말고, fail-fast로 멈추면 같은 단계에서 원인을 먼저 정리합니다.

⚠️ **주의**

선행 조건을 확인하지 못했거나 측정 상태가 불분명하면 다음 단계로 넘어가지 않습니다.


### 1) 고정 변수와 지원되는 Kubernetes 1.34 패치 선택

👁️ **설명**

Module 01의 `results/environment.json` 이 이미 `Standard_D16s_v5` 와 `koreacentral` 을 검증했더라도 AKS 생성 직전에 실제 지원 버전을 다시 조회합니다.

🟢 **실행**

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
      printf 'export K8S_VERSION=%q\n' "$K8S_VERSION"
    } >"$STATE_TMP"
  )
  chmod 600 "$STATE_TMP"
  mv "$STATE_TMP" "$WORKSHOP_STATE"
}

( set -euo pipefail
  LOCATION="koreacentral"
  RG="rg-vn2-hands-on-$RANDOM"
  VNET="vnet-vn2-hands-on"
  AKS_SUBNET="snet-aks"
  CG_SUBNET="cg"
  NAT_NAME="nat-vn2-hands-on"
  NAT_PIP_NAME="pip-vn2-hands-on"
  AKS="aks-vn2-hands-on"
  AKS_IDENTITY="id-aks-vn2-hands-on"
  AKS_IDENTITY_ID=""
  VM_SIZE="Standard_D16s_v5"

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
printf 'Using Kubernetes version %s with system VM %s\n' \
  "$K8S_VERSION" "$VM_SIZE"
```

📋 **예상 출력**

- `Using Kubernetes version ...` 한 줄이 보이면 state file과 고정 VM 크기가 함께 복구된 것입니다.

👁️ **설명**

`AKS_IDENTITY_ID` 는 Step 3에서 실제 ARM resource ID로 채워집니다. `results/workshop.env is the authoritative workshop state` 이므로 새 Cloud Shell에서는 항상 `source "$WORKSHOP_STATE"` 로 복구합니다. NAP은 활성화하지만 이 workshop에서는 custom NodePool을 만들지 않습니다.

### 2) custom VNet, delegated subnet, NAT Gateway 만들기

🟢 **실행**

```bash
WORKSHOP_STATE="results/workshop.env"

( set -euo pipefail
  if [[ ! -f "$WORKSHOP_STATE" ]]; then
    printf 'Missing %s. Run step 1 first.\n' "$WORKSHOP_STATE" >&2
    exit 1
  fi
  source "$WORKSHOP_STATE"

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

⚠️ **주의**

AKS subnet과 ACI `cg` subnet은 분리합니다. `cg`만 `Microsoft.ContainerInstance/containerGroups`에 위임하고 NAT Gateway를 연결합니다.

### 3) AKS용 user-assigned managed identity와 VNet 권한 준비

👁️ **설명**

NAP와 custom VNet을 함께 사용하므로 AKS 생성 전에 identity를 만들고 workshop VNet 전체 범위에 `Network Contributor`를 부여합니다.

🟢 **실행**

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

👁️ **설명**

`AKS_IDENTITY_ID`는 identity의 ARM resource ID이고, role assignment의 assignee는 `principalId`입니다. 두 값을 바꾸어 사용하지 않습니다.

### 4) NAP Auto와 fixed D16 system node로 AKS 만들기

🟢 **실행**

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

👁️ **설명**

`--node-provisioning-default-pools None` 은 AKS가 기본 NAP pool을 자동으로 만들지 않게 합니다. fixed system node는 `Standard_D16s_v5` 한 대이며, NAP은 활성화하지만 이 workshop에서는 custom NodePool을 만들지 않습니다.

### 5) kubelet identity 권한, kubeconfig, AKS foundation 확인

👁️ **설명**

VN2가 workshop RG와 AKS node RG의 리소스를 사용할 수 있도록 kubelet identity에 기존 Contributor 역할을 부여합니다.

🟢 **실행**

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

  az aks show -g "$RG" -n "$AKS" \
    --query '{nodeProvisioningMode:nodeProvisioningProfile.mode,nodeResourceGroup:nodeResourceGroup}' \
    -o json
  kubectl get nodes -o wide
)
```

📋 **예상 출력**

- `az aks show ...` 결과에서 `nodeProvisioningMode` 가 `Auto` 이고 `nodeResourceGroup` 값이 비어 있지 않아야 합니다.
- `kubectl get nodes -o wide` 결과에서 fixed system node 한 대가 Ready로 보여야 합니다.

👁️ **설명**

이 단계에서는 kubelet identity 권한과 foundation 상태만 확인합니다. custom NAP resource를 적용하거나 추가 NodePool을 만들지 않아도 이후 모듈에서 같은 AKS foundation을 계속 재사용할 수 있습니다.

## 완료 체크포인트

- `LOCATION`, `RG`, `VNET`, `AKS_SUBNET`, `CG_SUBNET`, `NAT_NAME`, `NAT_PIP_NAME`, `AKS`, `VM_SIZE`, `AKS_IDENTITY`, `AKS_IDENTITY_ID`, `K8S_VERSION` 이 `results/workshop.env`에 저장되었다.
- user-assigned managed identity가 VNet 범위 `Network Contributor`를 받았다.
- AKS가 Azure CNI, Standard Load Balancer, NAP Auto, default pools None으로 생성되었다.
- fixed system node는 `Standard_D16s_v5` 한 대다.
- kubelet identity가 node RG와 workshop RG 양쪽에 Contributor 권한을 받았다.
- `az aks show -g "$RG" -n "$AKS" --query '{nodeProvisioningMode:nodeProvisioningProfile.mode,nodeResourceGroup:nodeResourceGroup}' -o json` 결과가 정상이다.
- `kubectl get nodes -o wide` 로 foundation node 상태를 확인했다.
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
| `az aks show` 결과에 `nodeProvisioningMode` 가 `Auto` 로 나오지 않음 | `az aks show -g "$RG" -n "$AKS" --query '{nodeProvisioningMode:nodeProvisioningProfile.mode,nodeResourceGroup:nodeResourceGroup}' -o json` | AKS가 `--node-provisioning-mode Auto --node-provisioning-default-pools None` 으로 생성되었는지 다시 확인 |
| `kubectl get nodes -o wide` 에서 node가 Ready가 아님 | `kubectl get nodes -o wide` | `az aks get-credentials --resource-group "$RG" --name "$AKS" --overwrite-existing` 를 다시 실행하고 cluster provisioning 상태를 먼저 확인 |

## 이전/다음

- 이전: [Module 01](./01-prerequisites.md)
- 다음: [Module 03](./03-install-dual-vn2.md)
