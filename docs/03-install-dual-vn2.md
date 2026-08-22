# Module 03. 이중 VN2 설치와 standby pool 준비

## 목표

하나의 AKS 클러스터에 `vn2-ondemand` 와 `vn2-standby` 를 **동시에** 설치해 세 가지 node path(`aks`, `ondemand`, `standby`)를 고정합니다. 이후 네 가지 benchmark scenario는 이 세 가지 node path 위에서 실행되며, 두 standby scenario는 같은 `benchmark-path=standby` 경로를 쓰되 image cache 유무와 pool 상태만 다릅니다.

## 예상 소요 시간

20분

## 시작 전 상태

- Module 02에서 선언한 `RG`, `AKS`, `CG_SUBNET` shell 변수가 아직 현재 Cloud Shell 세션에 남아 있다.
- `CG_SUBNET` 값은 계속 `cg` 여야 한다.
- `az aks get-credentials` 가 이미 끝나 있어 현재 `kubectl` 컨텍스트가 이 실습용 AKS 를 가리킨다.
- 일반 AKS 노드에 `benchmark-path=aks` 라벨이 이미 붙어 있다.
- kubelet identity Contributor 권한과 Standby Pool Resource Provider RBAC가 이미 준비되었다.

## 진행 순서

1. Module 02에서 만든 `$RG`, `cg` subnet, AKS context 를 그대로 재사용하는지 확인합니다.
2. VN2 Helm chart 저장소를 추가하고 chart version `1.3410.26081102` 를 고정합니다.
3. `vn2-ondemand` 와 `vn2-standby` 를 서로 다른 namespace에 설치합니다.
4. cluster-scoped `virtual-node-admission-controller` webhook 소유권이 첫 번째 release 하나에만 있는지 확인합니다.
5. `benchmark-path=ondemand` 와 `benchmark-path=standby` virtual node 가 모두 Ready 인지 확인합니다.
6. standby pool을 정확히 하나만 찾고 `STANDBY_POOL` 로 export 한 뒤, healthy/running 5 상태를 기다립니다.

### 1) Module 02 변수와 AKS context 연속성 확인

```bash
cd ~/aci-vn2-performance-workshop

set -euo pipefail

: "${RG:?Run Module 02 first and keep the same shell session.}"
: "${AKS:?Run Module 02 first and keep the same shell session.}"
: "${CG_SUBNET:?Run Module 02 first and keep the same shell session.}"

if [[ "$CG_SUBNET" != "cg" ]]; then
  printf 'Expected CG_SUBNET to stay cg, found %s\n' "$CG_SUBNET" >&2
  exit 1
fi

kubectl config current-context
kubectl get nodes -L benchmark-path -o wide
```

여기서는 새 변수를 다시 만들지 않습니다. Module 02의 `$RG` 와 AKS context 를 그대로 이어 받아야 이후 모듈의 resource group, subnet, pool 조회가 모두 같은 실습 환경을 가리킵니다.

### 2) VN2 chart 저장소 추가와 pinned release 값 선언

```bash
helm repo add virtualnode \
  https://microsoft.github.io/virtualnodesOnAzureContainerInstances/
helm repo update

export VN2_CHART_VERSION="1.3410.26081102"
export ONDEMAND_RELEASE="vn2-ondemand"
export STANDBY_RELEASE="vn2-standby"
```

이 워크숍은 chart version을 고정합니다. `latest` 나 임의의 새 chart로 바꾸면 Helm value 이름, webhook 동작, standby profile 허용 범위가 달라져 실습 결과를 비교할 수 없습니다.

### 3) 두 release를 separate namespace 에 동시에 설치

`vn2-ondemand` 는 cluster-scoped admission controller 를 소유하는 첫 번째 release 입니다. `vn2-standby` 는 같은 클러스터에서 concurrent 하게 동작해야 하므로 release/namespace 를 분리하고 `admissionControllerReplicaCount=0` 으로 고정합니다.

```bash
helm upgrade --install vn2-ondemand virtualnode/virtualnode \
  --version "$VN2_CHART_VERSION" \
  --namespace vn2-ondemand \
  --create-namespace \
  --set fullnameOverride=vn2-ondemand \
  --set aciSubnetName=cg \
  --set aciResourceGroupName="$RG" \
  --set sandboxProviderType=OnDemand \
  --set nodeLabels="benchmark-path=ondemand"

helm upgrade --install vn2-standby virtualnode/virtualnode \
  --version "$VN2_CHART_VERSION" \
  --namespace vn2-standby \
  --create-namespace \
  --set fullnameOverride=vn2-standby \
  --set admissionControllerReplicaCount=0 \
  --set aciSubnetName=cg \
  --set aciResourceGroupName="$RG" \
  --set sandboxProviderType=StandbyPool \
  --set standbyPoolShareType=Node \
  --set standbyPool.standbyPoolsCpu=1 \
  --set standbyPool.standbyPoolsMemory=2 \
  --set standbyPool.maxReadyCapacity=5 \
  --set nodeLabels="benchmark-path=standby"
```

Standby 쪽은 `standbyPool.standbyPoolsCpu=1`, `standbyPool.standbyPoolsMemory=2`, `standbyPool.maxReadyCapacity=5` 를 그대로 유지합니다. 이 `1 vCPU / 2 GiB` 프로필이 현재 구독이나 지역 API에서 거부되면 더 큰 값을 자동으로 고르지 말고, 실패 원인과 허용 가능한 최소 프로필을 먼저 확인해야 합니다.

### 4) 왜 첫 번째 release만 cluster-scoped admission controller 를 소유해야 하는가

`virtual-node-admission-controller` 는 namespace 안의 Deployment가 아니라 cluster-scoped webhook 입니다. Helm은 cluster-scoped 리소스에 `meta.helm.sh/release-name` 과 `meta.helm.sh/release-namespace` annotation 으로 소유권을 기록하므로, 두 번째 release까지 같은 webhook 을 만들려고 하면 duplicate webhook ownership 충돌이 납니다.

아래 명령으로 실제 소유권을 확인합니다.

```bash
kubectl get validatingwebhookconfiguration virtual-node-admission-controller \
  -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}{" / "}{.metadata.annotations.meta\.helm\.sh/release-namespace}{"\n"}'

kubectl get deployment -A | grep admission-controller
helm list -A | grep '^vn2-'
```

정상이라면 첫 줄은 `vn2-ondemand / vn2-ondemand` 처럼 보입니다. `vn2-standby` namespace 쪽에서는 webhook 복제본을 만들지 않아야 하므로 `admissionControllerReplicaCount=0` 이 빠지면 안 됩니다.

### 5) 두 virtual node Ready 확인과 path 라벨 점검

```bash
kubectl wait --for=condition=Ready node \
  -l benchmark-path=ondemand --timeout=10m
kubectl wait --for=condition=Ready node \
  -l benchmark-path=standby --timeout=10m

kubectl get nodes -L benchmark-path -o wide
```

예상 출력은 환경마다 이름이 달라도 다음 구조를 포함해야 합니다.

```text
NAME                           STATUS   ROLES    AGE   VERSION   BENCHMARK-PATH
aks-nodepool1-12345678-vmss0   Ready    agent    ...   v1.34.x   aks
virtual-node-ondemand          Ready    agent    ...   v1.34.x   ondemand
virtual-node-standby           Ready    agent    ...   v1.34.x   standby
```

이 단계가 끝나면 세 가지 node path 는 모두 준비된 상태입니다. 이후 Module 04와 Module 05는 이 라벨만 바꿔 같은 workload를 네 가지 benchmark scenario로 실행합니다.

### 6) standby pool 하나를 정확히 찾고 `STANDBY_POOL` export

```bash
mapfile -t POOLS < <(az standby-container-group-pool list \
  --resource-group "$RG" \
  --query '[].name' -o tsv)

test "${#POOLS[@]}" -eq 1 || {
  printf 'Expected exactly one standby pool in %s, found %s\n' "$RG" "${#POOLS[@]}" >&2
  az standby-container-group-pool list --resource-group "$RG" --output table >&2
  exit 1
}

export STANDBY_POOL="${POOLS[0]}"
printf 'STANDBY_POOL=%s\n' "$STANDBY_POOL"
```

이 변수는 다음 모듈에서 그대로 재사용합니다. 이름을 다른 변수로 바꾸지 말고 `STANDBY_POOL` 하나만 유지해야 `run-benchmark.sh`, pool recycle, image cache 단계가 같은 대상을 가리킵니다.

### 7) healthy standby pool 과 running 5 확인

```bash
./scripts/check-standby-pool.sh \
  --resource-group "$RG" \
  --name "$STANDBY_POOL" \
  --expect-running 5 \
  --timeout-seconds 1200 \
  --interval-seconds 15

az standby-container-group-pool status \
  --resource-group "$RG" \
  --name "$STANDBY_POOL" \
  --version latest \
  --output json
```

성공 시 `check-standby-pool.sh` 는 다음과 비슷한 JSON을 출력합니다.

```json
{"creating":0,"deleting":0,"health":"healthy","provisioning_state":"Succeeded","running":5,"starting":0}
```

이는 standby pool 이 degraded pool 이 아니고, warm instance 다섯 개가 실제로 준비되었다는 뜻입니다. 이후 두 standby scenario는 같은 `benchmark-path=standby` 경로를 사용하지만, uncached/cached 차이는 image cache 적용 여부와 pool recycle 여부로만 만들어집니다.

## 완료 체크포인트

- `vn2-ondemand` 와 `vn2-standby` 가 서로 다른 namespace에 동시에 설치되었다.
- chart version `1.3410.26081102` 가 두 release 모두에 적용되었다.
- `virtual-node-admission-controller` cluster-scoped 소유권이 `vn2-ondemand` 하나에만 있다.
- `benchmark-path=aks`, `benchmark-path=ondemand`, `benchmark-path=standby` 가 `kubectl get nodes -L benchmark-path -o wide` 에서 모두 보인다.
- ondemand/standby virtual node 가 둘 다 Ready 상태다.
- standby pool이 정확히 하나만 발견되었고 `export STANDBY_POOL=...` 가 성공했다.
- `./scripts/check-standby-pool.sh --resource-group "$RG" --name "$STANDBY_POOL" --expect-running 5 --timeout-seconds 1200 --interval-seconds 15` 가 성공했다.
- 다음 모듈에서 `STANDBY_POOL` 과 `$RG` 를 그대로 재사용할 준비가 되었다.

## 문제 해결

| 증상 | 원인 후보 | 확인 명령 | 조치 |
| --- | --- | --- | --- |
| `kubectl wait` 가 오래 걸리고 VN2 Pod가 Pending 이다 | AKS 노드에 두 VN2 인프라를 동시에 올릴 8-vCPU/32-GiB headroom 이 부족함 | `kubectl get nodes -o wide`, `kubectl describe node "$(kubectl get nodes -l benchmark-path=aks -o jsonpath='{.items[0].metadata.name}')"`, `kubectl get pods -A -o wide`, `kubectl get events -A --sort-by=.metadata.creationTimestamp \| tail -n 40` | `Standard_D8s_v5` 이상으로 다시 만들거나, 다른 워크로드를 비운 뒤 Module 02부터 재시작 |
| Helm 설치가 webhook annotation 충돌로 실패한다 | duplicate webhook ownership: 두 release가 모두 `virtual-node-admission-controller` 를 소유하려고 함 | `kubectl get validatingwebhookconfiguration virtual-node-admission-controller -o yaml \| grep 'meta.helm.sh/release-'`, `helm status vn2-ondemand -n vn2-ondemand`, `helm status vn2-standby -n vn2-standby` | standby release에 `admissionControllerReplicaCount=0` 이 있는지 확인하고, 잘못 생성된 standby release를 제거한 뒤 다시 설치 |
| standby 설치가 곧바로 실패한다 | rejected 1 vCPU/2 GiB profile: 지역/API가 `1 vCPU / 2 GiB` 조합을 거부함 | `helm status vn2-standby -n vn2-standby`, `kubectl get events -n vn2-standby --sort-by=.metadata.creationTimestamp \| tail -n 20`, `az standby-container-group-pool list --resource-group "$RG" --output json` | 자동 대체하지 말고 현재 구독/지역에서 허용되는 더 큰 최소 profile을 확인한 뒤 값을 명시적으로 조정 |
| pool 이 생성되지 않거나 authorization 오류가 난다 | missing RBAC: Standby Pool Resource Provider 또는 kubelet identity 권한 누락 | `az role assignment list --assignee-object-id "$(az ad sp list --display-name 'Standby Pool Resource Provider' --query '[0].id' -o tsv)" --scope "/subscriptions/$(az account show --query id -o tsv)" --output table`, `az aks show -g "$RG" -n "$AKS" --query '{kubelet:identityProfile.kubeletidentity.objectId,nodeRg:nodeResourceGroup}' -o json` | Module 01의 세 가지 구독 역할과 Module 02의 kubelet Contributor 권한을 다시 부여한 뒤 Helm install 재시도 |
| pool status 가 healthy 로 바뀌지 않는다 | degraded pool 또는 quota/ACI 백엔드 문제 | `az standby-container-group-pool status --resource-group "$RG" --name "$STANDBY_POOL" --version latest --output json`, `az standby-container-group-pool list --resource-group "$RG" --output table`, `kubectl get nodes -l benchmark-path=standby -o wide`, `kubectl get events -A --sort-by=.metadata.creationTimestamp \| tail -n 40` | degraded 원인을 먼저 캡처하고 quota, provider 상태, region health 를 확인한 뒤 capacity가 5로 회복될 때까지 다음 모듈로 넘어가지 않음 |

## 이전/다음

- 이전: [Module 02](./02-azure-foundation.md)
- 다음: [Module 04](./04-baseline-ondemand-benchmark.md)
