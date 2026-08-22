# Module 02. Azure 기반 환경 준비

## 목표

워크숍에서 재현 가능한 측정을 위해 리소스 그룹, VNet, AKS subnet, delegated `cg` subnet, NAT Gateway, public IP, AKS 클러스터를 Korea Central에 일관된 이름과 구조로 준비합니다.

## 예상 소요 시간

30분

## 시작 전 상태

- Module 01의 preflight가 성공했다.
- 사용할 subscription ID와 Azure location이 확정되었다.
- 아직 workshop 리소스 그룹 이름과 네트워크 CIDR을 선언하지 않았다.

## 진행 순서

1. 실습 전용 환경 변수와 리소스 그룹 이름을 정합니다.
2. AKS subnet과 `Microsoft.ContainerInstance/containerGroups` delegated `cg` subnet을 포함한 VNet을 만듭니다.
3. `cg` subnet에 NAT Gateway와 public IP를 연결해 ACI outbound 경로를 고정합니다.
4. Azure CNI 기반 AKS 클러스터를 생성하고 노드 풀 준비를 확인합니다.
5. 이후 VN2 설치에서 재사용할 이름을 shell 변수 또는 메모에 남깁니다.

```bash
export LOCATION="koreacentral"
export WORKSHOP_RG="rg-aci-vn2-workshop"
export VNET_NAME="vnet-aci-vn2-workshop"
export AKS_SUBNET_NAME="snet-aks"
export CG_SUBNET_NAME="snet-cg"
export NAT_NAME="nat-aci-vn2"
export NAT_PIP_NAME="pip-aci-vn2"
export AKS_NAME="aks-aci-vn2"

az group create --name "$WORKSHOP_RG" --location "$LOCATION"
az network public-ip create --resource-group "$WORKSHOP_RG" --name "$NAT_PIP_NAME" --sku Standard
az network nat gateway create --resource-group "$WORKSHOP_RG" --name "$NAT_NAME" --public-ip-addresses "$NAT_PIP_NAME"
az network vnet create --resource-group "$WORKSHOP_RG" --name "$VNET_NAME" --address-prefixes 10.20.0.0/16 --subnet-name "$AKS_SUBNET_NAME" --subnet-prefixes 10.20.0.0/22
az network vnet subnet create --resource-group "$WORKSHOP_RG" --vnet-name "$VNET_NAME" --name "$CG_SUBNET_NAME" --address-prefixes 10.20.4.0/24 --delegations Microsoft.ContainerInstance/containerGroups
az network vnet subnet update --resource-group "$WORKSHOP_RG" --vnet-name "$VNET_NAME" --name "$CG_SUBNET_NAME" --nat-gateway "$NAT_NAME"
az aks create --resource-group "$WORKSHOP_RG" --name "$AKS_NAME" --network-plugin azure --generate-ssh-keys
az aks get-credentials --resource-group "$WORKSHOP_RG" --name "$AKS_NAME" --overwrite-existing
kubectl get nodes -o wide
```

여기서는 값이 모두 고정되기보다 구조가 맞는지가 중요합니다. 실제 VM SKU나 CIDR은 구독 상황에 맞춰 조정할 수 있지만, `cg` subnet delegation과 NAT Gateway 연결, Azure CNI 사용 여부는 타협하지 않습니다.

## 완료 체크포인트

- 리소스 그룹, NAT Gateway, public IP, VNet, 두 subnet이 모두 생성되었다.
- `cg` subnet에 delegation과 NAT Gateway 연결이 적용되었다.
- `az aks create` 가 성공하고 `kubectl get nodes` 가 응답한다.
- AKS가 Azure CNI 경로로 생성되었음을 확인했다.
- 다음 모듈에서 사용할 AKS 이름, RG 이름, subnet 이름을 메모했다.

## 이전/다음

- 이전: [Module 01](./01-prerequisites.md)
- 다음: [Module 03](./03-install-dual-vn2.md)
