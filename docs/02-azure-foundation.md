# Module 02. Azure 기반 환경 준비

## 목표

워크숍에서 재현 가능한 측정을 위해 Korea Central에 고정된 주소 체계의 VNet, delegated `cg` subnet, Standard public IP, NAT Gateway, Azure CNI 기반 AKS, 그리고 이후 VN2 설치에 필요한 kubelet identity 권한을 준비합니다.

## 예상 소요 시간

30분

## 시작 전 상태

- Module 01의 preflight가 성공했다.
- `results/environment.json` 이 존재한다.
- 사용할 subscription ID와 Azure location이 확정되었다.
- 아직 workshop 리소스 그룹 이름과 네트워크 CIDR을 선언하지 않았다.

## 진행 순서

1. 고정된 이름/주소 범위와 동적 Kubernetes `1.34.x` 버전을 shell 변수로 선언합니다.
2. `reserved`, `snet-aks`, `cg` subnet을 가진 VNet을 만들고 `cg` subnet에 delegation을 설정합니다.
3. Standard static public IP와 NAT Gateway를 만들고 `cg` subnet에 연결합니다.
4. Azure CNI 와 `Standard_D8s_v5` 를 사용해 AKS를 만듭니다.
5. kubelet identity에 workshop RG 와 node RG 양쪽 Contributor 권한을 주고, 참가자 kubeconfig 와 `benchmark-path=aks` 라벨을 준비합니다.

### 1) 고정 변수와 지원되는 Kubernetes 1.34 패치 선택

Module 01의 `results/environment.json` 이 이미 `Standard_D8s_v5` 와 `koreacentral` 을 검증했더라도, AKS 생성 직전에 실제 지원되는 `1.34.x` 패치 버전을 다시 조회해야 합니다.

```bash
cd ~/aci-vn2-performance-workshop

set -euo pipefail

LOCATION="koreacentral"
RG="rg-vn2-bench-$RANDOM"
VNET="vnet-vn2-bench"
AKS_SUBNET="snet-aks"
CG_SUBNET="cg"
NAT_NAME="nat-vn2-bench"
NAT_PIP_NAME="pip-vn2-bench"
AKS="aks-vn2-bench"
VM_SIZE="${VM_SIZE:-Standard_D8s_v5}"

K8S_VERSION="$(az aks get-versions \
  --location "$LOCATION" \
  --query "values[?version=='1.34'].patchVersions | [0]" \
  --output json | jq -r 'if type=="object" then (keys_unsorted | map(select(startswith("1.34."))) | sort_by(split(".")|map(tonumber)) | last // "") else "" end')"
if ! test -n "$K8S_VERSION"; then
  printf 'No supported Kubernetes 1.34.x version was returned for %s.\n' "$LOCATION" >&2
  exit 1
fi

printf 'Using Kubernetes version: %s\n' "$K8S_VERSION"
```

여기서는 `values[].version` 이 minor (`1.34`) 까지만 주어진다는 점 때문에 `patchVersions` 객체에서 실제 `1.34.x` 키를 골라야 합니다. `jq` 는 minor 자체가 없을 때 빈 문자열을 돌려주고, `1.34.9` 와 `1.34.10` 도 숫자 기준으로 정렬해 가장 최신 patch를 고릅니다. `K8S_VERSION` 이 비어 있으면 임의로 `1.33` 이나 `1.35` 를 넣지 말고, Korea Central 에서 실제 `1.34.x` patch가 반환될 때까지 멈추는 것이 맞습니다.

### 2) 고정 네트워크와 NAT Gateway 만들기

주소 범위는 문서와 테스트, 이후 모듈이 모두 공유하므로 그대로 사용합니다.

```bash
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

az network vnet subnet show -g "$RG" --vnet-name "$VNET" -n "$CG_SUBNET" \
  --query '{name:name,delegations:delegations[].serviceName,natGateway:natGateway.id}' \
  --output json
```

`cg` subnet은 반드시 `Microsoft.ContainerInstance/containerGroups` 로 delegation 되어 있어야 하며, NAT Gateway가 연결되어 있어야 ACI 기반 경로의 outbound 가 일관됩니다.

### 3) Azure CNI 기반 AKS 만들기

```bash
AKS_SUBNET_ID="$(az network vnet subnet show -g "$RG" \
  --vnet-name "$VNET" \
  -n "$AKS_SUBNET" \
  --query id \
  -o tsv)"
if [[ -z "$AKS_SUBNET_ID" ]]; then
  printf 'AKS subnet ID could not be resolved.\n' >&2
  exit 1
fi

az aks create -g "$RG" -n "$AKS" \
  --location "$LOCATION" \
  --node-count 1 \
  --node-vm-size "$VM_SIZE" \
  --kubernetes-version "$K8S_VERSION" \
  --network-plugin azure \
  --vnet-subnet-id "$AKS_SUBNET_ID" \
  --service-cidr 172.16.0.0/16 \
  --dns-service-ip 172.16.0.10 \
  --enable-managed-identity \
  --generate-ssh-keys
```

여기서 `--network-plugin azure` 는 필수입니다. 이 워크숍은 Azure CNI가 아닌 AKS 구성을 지원하지 않습니다. VNet 주소 공간이 `10.0.0.0/8` 이므로 AKS service CIDR 과 DNS service IP 는 그 범위 밖의 private 대역(`172.16.0.0/16`, `172.16.0.10`)을 유지해야 겹침이 없습니다.

### 4) kubelet identity 권한 부여, kubeconfig 가져오기, 일반 노드 라벨링

Module 03부터는 AKS kubelet identity가 workshop resource group 과 node resource group 양쪽에 접근해야 합니다. query 문자열 `identityProfile.kubeletidentity.objectId` 와 `nodeResourceGroup` 을 그대로 사용하세요.

```bash
KUBELET_OBJECT_ID="$(az aks show -g "$RG" -n "$AKS" \
  --query identityProfile.kubeletidentity.objectId \
  -o tsv)"
if [[ -z "$KUBELET_OBJECT_ID" ]]; then
  printf 'AKS kubelet identityProfile.kubeletidentity.objectId could not be resolved.\n' >&2
  exit 1
fi

NODE_RG="$(az aks show -g "$RG" -n "$AKS" --query nodeResourceGroup -o tsv)"
if [[ -z "$NODE_RG" ]]; then
  printf 'AKS nodeResourceGroup could not be resolved.\n' >&2
  exit 1
fi

NODE_RG_ID="$(az group show -n "$NODE_RG" --query id -o tsv)"
WORKSHOP_RG_ID="$(az group show -n "$RG" --query id -o tsv)"
if [[ -z "$NODE_RG_ID" || -z "$WORKSHOP_RG_ID" ]]; then
  printf 'Resource group IDs for kubelet role assignment could not be resolved.\n' >&2
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

az aks get-credentials --resource-group "$RG" --name "$AKS" --overwrite-existing

REGULAR_NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
if [[ -z "$REGULAR_NODE" ]]; then
  printf 'No AKS node name was returned by kubectl.\n' >&2
  exit 1
fi

kubectl label node "$REGULAR_NODE" benchmark-path=aks --overwrite
kubectl get nodes --show-labels
```

이제 참가자 kubeconfig 는 현재 AKS 를 가리키고, 최소 한 개의 일반 노드에 `benchmark-path=aks` 가 존재해야 합니다.

## 완료 체크포인트

- `RG`, `VNET`, `AKS_SUBNET`, `CG_SUBNET`, `AKS`, `VM_SIZE`, `K8S_VERSION` 값이 모두 결정되었다.
- 리소스 그룹, NAT Gateway, Standard public IP, VNet, 세 subnet이 모두 생성되었다.
- `cg` subnet에 delegation과 NAT Gateway 연결이 적용되었다.
- `az aks create` 가 성공하고 `kubectl get nodes` 가 응답한다.
- AKS가 Azure CNI 경로로 생성되었음을 확인했다.
- kubelet identity가 node RG 와 workshop RG 양쪽에 Contributor 권한을 받았다.
- 일반 AKS 노드에 `benchmark-path=aks` 라벨이 적용되었다.
- 다음 모듈에서 사용할 AKS 이름, RG 이름, subnet 이름을 메모했다.

## 문제 해결

| 증상 | 확인할 것 | 확인 명령 | 조치 |
| --- | --- | --- | --- |
| `No supported Kubernetes 1.34.x version` | Korea Central 의 `1.34` patch map | `az aks get-versions --location koreacentral --query "values[?version=='1.34'].patchVersions | [0]" --output json \| jq -r 'if type=="object" then (keys_unsorted \| map(select(startswith("1.34."))) \| sort_by(split(".")\|map(tonumber)) \| last // "") else "" end'` | 다른 버전을 강제로 넣지 말고, 결과가 비어 있으면 해당 minor 가 아직 없다는 뜻으로 보고 교육용 구독/지역 상태를 확인하거나 `1.34.x` 가 다시 노출될 때까지 대기 |
| `cg` subnet delegation 누락 | delegation 이름 | `az network vnet subnet show -g "$RG" --vnet-name "$VNET" -n "$CG_SUBNET" --query delegations[].serviceName -o tsv` | `--delegations Microsoft.ContainerInstance/containerGroups` 를 다시 적용 |
| VN2 outbound 오류가 걱정됨 | NAT 연결 여부 | `az network vnet subnet show -g "$RG" --vnet-name "$VNET" -n "$CG_SUBNET" --query natGateway.id -o tsv` | `az network vnet subnet update ... --nat-gateway "$NAT_NAME"` 재실행 |
| `az aks create` 가 quota/SKU 로 실패함 | Module 01 결과 | `cat results/environment.json` | preflight를 다시 실행하고 `Standard_D8s_v5` headroom 을 먼저 해결 |
| kubelet role assignment 가 실패함 | kubelet identity 값 | `az aks show -g "$RG" -n "$AKS" --query '{kubelet:identityProfile.kubeletidentity.objectId,nodeRg:nodeResourceGroup}' -o json` | 값이 비어 있지 않은지 확인 후 두 scope 모두에 Contributor 재부여 |

## 이전/다음

- 이전: [Module 01](./01-prerequisites.md)
- 다음: [Module 03](./03-install-dual-vn2.md)
