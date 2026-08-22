# Module 03. 이중 VN2 설치와 경로 라벨 준비

## 목표

하나의 AKS 클러스터에 `vn2-ondemand` 와 `vn2-standby` Helm release를 동시에 설치하고, `benchmark-path=ondemand` 및 `benchmark-path=standby` 라벨을 통해 네 가지 측정 경로를 분리합니다.

## 예상 소요 시간

20분

## 시작 전 상태

- Module 02에서 AKS 클러스터와 `cg` subnet 준비가 끝났다.
- `kubectl` 과 `helm` 이 현재 클러스터에 연결되어 있다.
- `WORKSHOP_RG`, `AKS_NAME`, `CG_SUBNET_NAME` 같은 핵심 값이 shell 변수에 남아 있다.

## 진행 순서

1. VN2 Helm chart 저장소와 chart version `1.3410.26081102` 를 확인합니다.
2. `vn2-ondemand` namespace와 `vn2-standby` namespace를 분리합니다.
3. admission controller는 `vn2-ondemand` 에만 활성화하고 `vn2-standby` 는 `admissionControllerReplicaCount=0` 으로 고정합니다.
4. 두 release에 서로 다른 `benchmark-path` 라벨을 적용해 `ondemand`, `standby` 경로를 분리합니다.
5. 일반 AKS 노드에는 `benchmark-path=aks` 라벨을 추가해 기준선 경로를 명시합니다.

```bash
export VN2_CHART_VERSION="1.3410.26081102"
export ONDEMAND_NS="vn2-ondemand"
export STANDBY_NS="vn2-standby"

kubectl create namespace "$ONDEMAND_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$STANDBY_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label nodes <aks-node-name> benchmark-path=aks --overwrite

helm upgrade --install vn2-ondemand <vn2-chart-ref> \
  --namespace "$ONDEMAND_NS" \
  --version "$VN2_CHART_VERSION" \
  --set nodeLabels.benchmark-path=ondemand

helm upgrade --install vn2-standby <vn2-chart-ref> \
  --namespace "$STANDBY_NS" \
  --version "$VN2_CHART_VERSION" \
  --set nodeLabels.benchmark-path=standby \
  --set admissionControllerReplicaCount=0 \
  --set sandboxProviderType=StandbyPool

kubectl get nodes --show-labels | grep 'benchmark-path='
./scripts/check-standby-pool.sh -g "$WORKSHOP_RG" -n <standby-pool-name> --expect-running 5 --timeout-seconds 1200 --interval-seconds 15
```

이 단계의 목적은 설치 세부 옵션을 모두 암기하는 것이 아니라, OnDemand와 Standby release가 동시에 살아 있어야 이후 벤치마크가 공정해진다는 점을 확인하는 것입니다. 한쪽 release만 남겨 놓고 번갈아 설치하면 image pull, admission controller, pool warm-up 상태가 달라져 결과 비교가 흔들립니다.

## 완료 체크포인트

- `vn2-ondemand` 와 `vn2-standby` release가 동시에 설치되었다.
- 일반 AKS 노드에 `benchmark-path=aks` 라벨이 적용되었다.
- virtual node 또는 관련 node 객체에서 `benchmark-path=ondemand`, `benchmark-path=standby` 라벨이 확인되었다.
- standby pool health 확인 명령이 성공해 running capacity 5를 반환했다.
- 다음 모듈에서 사용할 standby pool 이름을 확보했다.

## 이전/다음

- 이전: [Module 02](./02-azure-foundation.md)
- 다음: [Module 04](./04-baseline-ondemand-benchmark.md)
