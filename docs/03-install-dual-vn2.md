# 03. 이중 VN2 설치와 StandbyPool 준비

> 동일 AKS 클러스터에 `vn2-ondemand`와 `vn2-standby`를 함께 설치하고, `benchmark-path`와 `STANDBY_POOL` 상태를 다음 모듈까지 그대로 이어갑니다.


## 목표

이 모듈을 완료하면 다음을 할 수 있습니다.

- `results/workshop.env` 와 AKS context를 같은 workshop state로 복구할 수 있습니다.
- chart version `1.3410.26081102` 를 고정한 채 `vn2-ondemand` 와 `vn2-standby` 를 동시에 설치할 수 있습니다.
- 하나의 AKS 클러스터에서 세 가지 node path(`aks-nap`, `ondemand`, `standby`)를 분리해 유지할 수 있습니다.
- image cache 유무까지 포함한 네 가지 benchmark scenario를 같은 standby path 위에서 구분해 설명할 수 있습니다.
- `STANDBY_POOL` 이름과 pool 상태를 다음 모듈까지 그대로 이어 갈 수 있습니다.
- fixed system node와 분리된 NAP benchmark NodePool은 0개 node에서 시작하는 계약을 유지할 수 있습니다.
- `benchmark-path=ondemand`, `benchmark-path=standby`, `workshop-nap` 0-state를 같은 클러스터에서 분리해 확인할 수 있습니다.
- `STANDBY_POOL` 과 release 정보를 원자적으로 다시 저장해 Module 04 이후에도 재사용할 수 있습니다.

## 예상 소요 시간

20분

## 시작 전 상태

- Module 02가 성공해 `results/workshop.env` 가 존재한다.
- `results/workshop.env` 에는 최소한 `RG`, `AKS`, `CG_SUBNET`, `K8S_VERSION`, `AKS_IDENTITY_ID`, `NAP_VM_SIZE`, `NAP_NODEPOOL` 이 저장되어 있다.
- `CG_SUBNET` 값은 계속 `cg` 여야 한다.
- `az aks get-credentials` 가 이미 끝나 있어 현재 `kubectl` 컨텍스트가 이 실습용 AKS 를 가리키거나, fresh Cloud Shell 에서 다시 불러올 준비가 되어 있다.
- `NodePool/workshop-nap`은 Ready이고 `karpenter.sh/nodepool=workshop-nap` node와 NodeClaim은 0개다.
- fixed system node에는 benchmark routing label이 없다.
- kubelet identity Contributor 권한과 Standby Pool Resource Provider RBAC가 이미 준비되었다.


## 태그 범례

| 태그 | 의미 |
|------|------|
| 🟢 **실행** | 참가자가 직접 입력하거나 수행해야 하는 단계 |
| 👁️ **설명** | 왜 이 단계를 하는지 이해하기 위한 읽기 전용 안내 |
| 📋 **예상 출력** | 실행 결과와 비교할 기준 출력 |
| ⚠️ **주의** | 비용, 순서, 안전성, 계약 조건 안내 |


## 진행 순서

1. Module 02에서 만든 state file을 먼저 source 하고, `$RG`, `cg` subnet, AKS context와 NAP zero-capacity 상태를 그대로 재사용하는지 확인합니다.
2. VN2 Helm chart 저장소를 추가하고 chart version `1.3410.26081102` 를 고정합니다.
3. `vn2-ondemand` 와 `vn2-standby` 를 서로 다른 namespace에 설치합니다.
4. cluster-scoped `virtual-node-admission-controller` webhook 소유권이 첫 번째 release 하나에만 있는지 확인합니다.
5. `benchmark-path=ondemand` 와 `benchmark-path=standby` virtual node 가 모두 Ready 인지 확인합니다.
6. standby pool을 정확히 하나만 찾고 `STANDBY_POOL` 로 export 한 뒤, healthy/running 5 상태를 기다립니다.
7. 마지막에는 Module 02 키를 보존한 채 `results/workshop.env` 를 원자적으로 다시 써서 Module 04 이후에도 같은 상태를 복구할 수 있게 합니다.


## 0. 세션 재연결 시 상태 복구 (선택)

<details>
<summary>fresh Cloud Shell에서 workshop state와 kubeconfig 복구 명령 보기</summary>

👁️ **설명**

같은 shell을 계속 사용 중이면 이 절은 건너뜁니다. 새 Cloud Shell이라면 `results/workshop.env`와 kubeconfig를 먼저 복구한 뒤 1단계부터 다시 확인합니다.

🟢 **실행**

```bash
cd ~/aci-vn2-performance-workshop
source results/workshop.env
az aks get-credentials --resource-group "$RG" --name "$AKS" --overwrite-existing
```

📋 **예상 출력**

- `RG`, `AKS`, `CG_SUBNET`, `NAP_NODEPOOL` 같은 workshop state를 그대로 다시 사용할 수 있습니다.
- kubeconfig가 현재 실습용 AKS를 다시 가리키면 1단계부터 이어서 진행할 수 있습니다.

</details>

👁️ **설명**

아래 단계는 설명 → 실행 → 예상 출력 → 주의 순서로 읽습니다. 코드 블록은 순서를 바꾸지 말고, fail-fast로 멈추면 같은 단계에서 원인을 먼저 정리합니다.

⚠️ **주의**

선행 조건을 확인하지 못했거나 측정 상태가 불분명하면 다음 단계로 넘어가지 않습니다.


### 1) Module 02 state file 과 AKS context 연속성 확인

🟢 **실행**

```bash
cd ~/aci-vn2-performance-workshop

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
      printf 'export VN2_CHART_VERSION=%q\n' "$VN2_CHART_VERSION"
      printf 'export ONDEMAND_RELEASE=%q\n' "$ONDEMAND_RELEASE"
      printf 'export STANDBY_RELEASE=%q\n' "$STANDBY_RELEASE"
      if [[ -n "${STANDBY_POOL:-}" ]]; then
        printf 'export STANDBY_POOL=%q\n' "$STANDBY_POOL"
      fi
    } >"$STATE_TMP"
  )
  chmod 600 "$STATE_TMP"
  mv "$STATE_TMP" "$WORKSHOP_STATE"
}

( set -euo pipefail
  if [[ ! -f "$WORKSHOP_STATE" ]]; then
    printf 'Missing %s. Run Module 02 first or recover the exact workshop state before continuing.\n' "$WORKSHOP_STATE" >&2
    exit 1
  fi
  source "$WORKSHOP_STATE"
  az aks get-credentials --resource-group "$RG" --name "$AKS" --overwrite-existing

  : "${RG:?Run Module 02 first or recover results/workshop.env before continuing.}"
  : "${AKS:?Run Module 02 first or recover results/workshop.env before continuing.}"
  : "${CG_SUBNET:?Run Module 02 first or recover results/workshop.env before continuing.}"
  : "${AKS_IDENTITY:?Run Module 02 first or recover results/workshop.env before continuing.}"
  : "${AKS_IDENTITY_ID:?Run Module 02 first or recover results/workshop.env before continuing.}"
  : "${NAP_VM_SIZE:?Run Module 02 first or recover results/workshop.env before continuing.}"
  : "${NAP_NODEPOOL:?Run Module 02 first or recover results/workshop.env before continuing.}"

  if [[ "$CG_SUBNET" != "cg" ]]; then
    printf 'Expected CG_SUBNET to stay cg, found %s\n' "$CG_SUBNET" >&2
    exit 1
  fi

  kubectl config current-context
  ./scripts/check-nap-capacity.sh \
    --name "$NAP_NODEPOOL" \
    --expect-nodes 0 \
    --expect-nodeclaims 0 \
    --timeout-seconds 1200 \
    --interval-seconds 15
  kubectl get nodes -l karpenter.sh/nodepool=workshop-nap
  kubectl get nodes -L benchmark-path -o wide
)
```

👁️ **설명**

여기서는 새 변수를 다시 만들지 않습니다. Module 02의 `$RG`, AKS context와 `workshop-nap` zero-capacity 상태를 그대로 이어 받아야 이후 모듈의 resource group, subnet, pool 조회가 모두 같은 실습 환경을 가리킵니다. `results/workshop.env is the authoritative workshop state` 이므로 fresh Cloud Shell 에서는 먼저 이 파일을 source 한 뒤 같은 확인을 다시 실행합니다.

### 2) VN2 chart 저장소 추가와 pinned release 값 선언

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
      printf 'export NAP_VM_SIZE=%q\n' "$NAP_VM_SIZE"
      printf 'export NAP_NODEPOOL=%q\n' "$NAP_NODEPOOL"
      printf 'export K8S_VERSION=%q\n' "$K8S_VERSION"
      printf 'export VN2_CHART_VERSION=%q\n' "$VN2_CHART_VERSION"
      printf 'export ONDEMAND_RELEASE=%q\n' "$ONDEMAND_RELEASE"
      printf 'export STANDBY_RELEASE=%q\n' "$STANDBY_RELEASE"
      if [[ -n "${STANDBY_POOL:-}" ]]; then
        printf 'export STANDBY_POOL=%q\n' "$STANDBY_POOL"
      fi
    } >"$STATE_TMP"
  )
  chmod 600 "$STATE_TMP"
  mv "$STATE_TMP" "$WORKSHOP_STATE"
}

if [[ ! -f "$WORKSHOP_STATE" ]]; then
  printf 'Missing %s. Recover the exact workshop state before continuing.\n' "$WORKSHOP_STATE" >&2
  exit 1
fi
source "$WORKSHOP_STATE"

helm repo add virtualnode \
  https://microsoft.github.io/virtualnodesOnAzureContainerInstances/
helm repo update

export VN2_CHART_VERSION="1.3410.26081102"
export ONDEMAND_RELEASE="vn2-ondemand"
export STANDBY_RELEASE="vn2-standby"
unset STANDBY_POOL

persist_workshop_state
source "$WORKSHOP_STATE"
```

👁️ **설명**

이 워크숍은 chart version을 고정합니다. `latest` 나 임의의 새 chart로 바꾸면 Helm value 이름, webhook 동작, standby profile 허용 범위가 달라져 실습 결과를 비교할 수 없습니다. Step 2가 끝나자마자 `results/workshop.env` 를 원자적으로 다시 써서 fresh Cloud Shell 이 step 6부터 재개되더라도 `VN2_CHART_VERSION`, `ONDEMAND_RELEASE`, `STANDBY_RELEASE` 는 이미 복구되고, 아직 존재하지 않는 `STANDBY_POOL` 은 stale 값 없이 비어 있는 상태로 남깁니다.

### 3) 두 release를 separate namespace 에 동시에 설치

👁️ **설명**

`vn2-ondemand` 는 cluster-scoped admission controller 를 소유하는 첫 번째 release 입니다. `vn2-standby` 는 같은 클러스터에서 concurrent 하게 동작해야 하므로 release/namespace 를 분리하고 `admissionControllerReplicaCount=0` 으로 고정합니다.

🟢 **실행**

```bash
WORKSHOP_STATE="results/workshop.env"
if [[ ! -f "$WORKSHOP_STATE" ]]; then
  printf 'Missing %s. Recover the exact workshop state before installing VN2.\n' "$WORKSHOP_STATE" >&2
  exit 1
fi
source "$WORKSHOP_STATE"

( set -euo pipefail
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
)
```

⚠️ **주의**

Standby 쪽은 `standbyPool.standbyPoolsCpu=1`, `standbyPool.standbyPoolsMemory=2`, `standbyPool.maxReadyCapacity=5` 를 그대로 유지합니다. 이 `1 vCPU / 2 GiB` 프로필이 현재 구독이나 지역 API에서 거부되면 더 큰 값을 자동으로 고르지 말고, 실패 원인과 허용 가능한 최소 프로필을 먼저 확인해야 합니다.

### 4) 왜 첫 번째 release만 cluster-scoped admission controller 를 소유해야 하는가

👁️ **설명**

`virtual-node-admission-controller` 는 namespace 안의 Deployment가 아니라 cluster-scoped webhook 입니다. Helm은 cluster-scoped 리소스에 `meta.helm.sh/release-name` 과 `meta.helm.sh/release-namespace` annotation 으로 소유권을 기록하므로, 두 번째 release까지 같은 webhook 을 만들려고 하면 duplicate webhook ownership 충돌이 납니다.

🟢 **실행**

아래 명령으로 실제 소유권을 확인합니다.

```bash
WORKSHOP_STATE="results/workshop.env"
if [[ ! -f "$WORKSHOP_STATE" ]]; then
  printf 'Missing %s. Recover the exact workshop state before checking webhook ownership.\n' "$WORKSHOP_STATE" >&2
  exit 1
fi
source "$WORKSHOP_STATE"

kubectl get mutatingwebhookconfiguration virtual-node-admission-controller \
  -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}{" / "}{.metadata.annotations.meta\.helm\.sh/release-namespace}{"\n"}'

kubectl get deployment -A | grep admission-controller
helm list -A | grep '^vn2-'
```

📋 **예상 출력**

정상이라면 첫 줄은 `vn2-ondemand / vn2-ondemand` 처럼 보입니다. `vn2-standby` namespace 쪽에서는 webhook 복제본을 만들지 않아야 하므로 `admissionControllerReplicaCount=0` 이 빠지면 안 됩니다.

### 5) 두 virtual node Ready 확인과 path 라벨 점검

🟢 **실행**

```bash
WORKSHOP_STATE="results/workshop.env"
if [[ ! -f "$WORKSHOP_STATE" ]]; then
  printf 'Missing %s. Recover the exact workshop state before waiting for virtual nodes.\n' "$WORKSHOP_STATE" >&2
  exit 1
fi
source "$WORKSHOP_STATE"

( set -euo pipefail
  for label in ondemand standby; do
    deadline=$((SECONDS + 600))

    until kubectl get nodes -l "benchmark-path=${label}" --no-headers 2>/dev/null | grep -q .; do
      if (( SECONDS >= deadline )); then
        printf 'Label benchmark-path=%s did not appear within 10 minutes\n' "${label}" >&2
        kubectl get nodes -L benchmark-path -o wide >&2
        kubectl get pods -A -o wide >&2
        exit 1
      fi
      sleep 10
    done

    kubectl wait --for=condition=Ready node \
      -l "benchmark-path=${label}" --timeout=10m
  done

  kubectl get nodes -L benchmark-path -o wide
)
```

👁️ **설명**

`kubectl wait` 는 label 이 아직 안 생긴 짧은 race 구간에서는 바로 끝날 수 있으므로, 위처럼 먼저 label 등장을 최대 10분 동안 bounded polling 한 뒤 Ready wait 로 넘어갑니다. 이 단계가 의미하는 capacity 기준은 16-vCPU/64-GiB fixed system node 한 대가 두 VN2 infrastructure release와 cluster system Pod를 안정적으로 호스팅해야 한다는 것입니다. Benchmark Pod는 이 node에 배치하지 않습니다.

📋 **예상 출력**

예상 출력은 환경마다 이름이 달라도 다음 구조를 포함해야 합니다.

```text
NAME                           STATUS   ROLES    AGE   VERSION   BENCHMARK-PATH
aks-system-12345678-vmss0      Ready    agent    ...   v1.34.x
virtual-node-ondemand          Ready    agent    ...   v1.34.x   ondemand
virtual-node-standby           Ready    agent    ...   v1.34.x   standby
```

이 단계가 끝나면 VN2 두 path는 Ready이고 NAP path는 NodePool만 Ready인 채 0개 node입니다. 이후 Module 04에서 `aks-nap` workload가 Pending될 때만 `Standard_D4s_v5` node가 생성됩니다.

### 6) standby pool 하나를 정확히 찾고 `STANDBY_POOL` export

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
      printf 'export NAP_VM_SIZE=%q\n' "$NAP_VM_SIZE"
      printf 'export NAP_NODEPOOL=%q\n' "$NAP_NODEPOOL"
      printf 'export K8S_VERSION=%q\n' "$K8S_VERSION"
      printf 'export VN2_CHART_VERSION=%q\n' "$VN2_CHART_VERSION"
      printf 'export ONDEMAND_RELEASE=%q\n' "$ONDEMAND_RELEASE"
      printf 'export STANDBY_RELEASE=%q\n' "$STANDBY_RELEASE"
      if [[ -n "${STANDBY_POOL:-}" ]]; then
        printf 'export STANDBY_POOL=%q\n' "$STANDBY_POOL"
      fi
    } >"$STATE_TMP"
  )
  chmod 600 "$STATE_TMP"
  mv "$STATE_TMP" "$WORKSHOP_STATE"
}

if [[ ! -f "$WORKSHOP_STATE" ]]; then
  printf 'Missing %s. Recover the exact workshop state before locating the standby pool.\n' "$WORKSHOP_STATE" >&2
  exit 1
fi
source "$WORKSHOP_STATE"

( set -euo pipefail
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
  persist_workshop_state
)

source "$WORKSHOP_STATE"
```

👁️ **설명**

이 변수는 다음 모듈에서 그대로 재사용합니다. 이름을 다른 변수로 바꾸지 말고 `STANDBY_POOL` 하나만 유지해야 `run-benchmark.sh`, pool recycle, image cache 단계가 같은 대상을 가리킵니다. Module 03는 이전 파일 끝에 export 를 덧붙이지 않고 전체 state file 을 원자적으로 다시 써서 이전 키와 새 키가 ambiguity 없이 하나씩만 남게 합니다.

### 7) healthy standby pool 과 running 5 확인

🟢 **실행**

```bash
WORKSHOP_STATE="results/workshop.env"
if [[ ! -f "$WORKSHOP_STATE" ]]; then
  printf 'Missing %s. Recover the exact workshop state before validating the standby pool.\n' "$WORKSHOP_STATE" >&2
  exit 1
fi
source "$WORKSHOP_STATE"

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

📋 **예상 출력**

성공 시 `check-standby-pool.sh` 는 다음과 비슷한 JSON을 출력합니다.

```json
{"creating":0,"deleting":0,"health":"healthy","provisioning_state":"Succeeded","running":5,"starting":0}
```

이는 standby pool 이 degraded pool 이 아니고, warm instance 다섯 개가 실제로 준비되었다는 뜻입니다. 이후 두 standby scenario는 같은 `benchmark-path=standby` 경로를 사용하지만, uncached/cached 차이는 image cache 적용 여부와 pool recycle 여부로만 만들어집니다.

## 완료 체크포인트

- `vn2-ondemand` 와 `vn2-standby` 가 서로 다른 namespace에 동시에 설치되었다.
- chart version `1.3410.26081102` 가 두 release 모두에 적용되었다.
- `virtual-node-admission-controller` cluster-scoped 소유권이 `vn2-ondemand` 하나에만 있다.
- fixed system node에는 benchmark label이 없고, `benchmark-path=ondemand`, `benchmark-path=standby` virtual node만 Ready로 보인다.
- `workshop-nap` NodePool은 Ready이며 benchmark 시작 전 node와 NodeClaim이 0개다.
- ondemand/standby virtual node 가 둘 다 Ready 상태다.
- standby pool이 정확히 하나만 발견되었고 `export STANDBY_POOL=...` 가 성공했다.
- `results/workshop.env` 가 Module 02 키를 유지한 채 `VN2_CHART_VERSION`, `ONDEMAND_RELEASE`, `STANDBY_RELEASE`, `STANDBY_POOL` 로 다시 저장되었다.
- `./scripts/check-standby-pool.sh --resource-group "$RG" --name "$STANDBY_POOL" --expect-running 5 --timeout-seconds 1200 --interval-seconds 15` 가 성공했다.
- 다음 모듈에서 `STANDBY_POOL` 과 `$RG` 를 그대로 재사용할 준비가 되었다.

## 문제 해결

| 증상 | 원인 후보 | 확인 명령 | 조치 |
| --- | --- | --- | --- |
| `kubectl wait` 가 오래 걸리고 VN2 Pod가 Pending 이다 | fixed system node에서 두 VN2 infrastructure release를 실행할 16-vCPU/64-GiB capacity가 부족함 | `kubectl get nodes -l kubernetes.azure.com/mode=system -o wide`, `kubectl get pods -A -o wide`, `kubectl get events -A --sort-by=.metadata.creationTimestamp \| tail -n 40` | `Standard_D16s_v5` system node 한 대 기준으로 다시 만들거나 다른 workload를 비운 뒤 Module 02부터 재시작 |
| Helm 설치가 webhook annotation 충돌로 실패한다 | duplicate webhook ownership: 두 release가 모두 `virtual-node-admission-controller` 를 소유하려고 함 | `kubectl get mutatingwebhookconfiguration virtual-node-admission-controller -o yaml \| grep 'meta.helm.sh/release-'`, `helm status vn2-ondemand -n vn2-ondemand`, `helm status vn2-standby -n vn2-standby` | standby release에 `admissionControllerReplicaCount=0` 이 있는지 확인하고, 잘못 생성된 standby release를 제거한 뒤 다시 설치 |
| standby 설치가 곧바로 실패한다 | rejected 1 vCPU/2 GiB profile: 지역/API가 `1 vCPU / 2 GiB` 조합을 거부함 | `helm status vn2-standby -n vn2-standby`, `kubectl get events -n vn2-standby --sort-by=.metadata.creationTimestamp \| tail -n 20`, `az standby-container-group-pool list --resource-group "$RG" --output json` | 자동 대체하지 말고 현재 구독/지역에서 허용되는 더 큰 최소 profile을 확인한 뒤 값을 명시적으로 조정 |
| pool 이 생성되지 않거나 authorization 오류가 난다 | missing RBAC: Standby Pool Resource Provider 또는 kubelet identity 권한 누락 | `az role assignment list --assignee-object-id "$(az ad sp list --display-name 'Standby Pool Resource Provider' --query '[0].id' -o tsv)" --scope "/subscriptions/$(az account show --query id -o tsv)" --output table`, `az aks show -g "$RG" -n "$AKS" --query '{kubelet:identityProfile.kubeletidentity.objectId,nodeRg:nodeResourceGroup}' -o json` | Module 01의 세 가지 구독 역할과 Module 02의 kubelet Contributor 권한을 다시 부여한 뒤 Helm install 재시도 |
| pool status 가 healthy 로 바뀌지 않는다 | degraded pool 또는 quota/ACI 백엔드 문제 | `az standby-container-group-pool status --resource-group "$RG" --name "$STANDBY_POOL" --version latest --output json`, `az standby-container-group-pool list --resource-group "$RG" --output table`, `kubectl get nodes -l benchmark-path=standby -o wide`, `kubectl get events -A --sort-by=.metadata.creationTimestamp \| tail -n 40` | degraded 원인을 먼저 캡처하고 quota, provider 상태, region health 를 확인한 뒤 capacity가 5로 회복될 때까지 다음 모듈로 넘어가지 않음 |

## 이전/다음

- 이전: [Module 02](./02-azure-foundation.md)
- 다음: [Module 04](./04-baseline-ondemand-benchmark.md)
