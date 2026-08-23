# Korea Central AKS NAP and VN2 live rehearsal reference

이 reference는 **2026-08-23** Korea Central에서 실행한 실제 live rehearsal 결과입니다. 측정 구간은 `2026-08-23T14:27:41.636228Z`부터 `2026-08-23T14:53:59.675300Z`까지이며, 각 시나리오는 **5 Pods × 3 runs**로 실행했습니다.

## 환경과 방법

| 항목 | 측정 조건 |
| --- | --- |
| Region | `koreacentral` |
| AKS | Kubernetes `1.34.9`, fixed system node 1대 |
| System node | `Standard_D16s_v5` |
| Managed NAP | `AKSNodeClass` `karpenter.azure.com/v1beta1`, `NodePool` `karpenter.sh/v1` |
| NAP node | on-demand `Standard_D4s_v5`, 최대 1대 |
| VN2 | Helm chart/app `1.3410.26081102` |
| StandbyPool | benchmark 전후 `healthy`, `running=5` |
| Benchmark image | `mcr.microsoft.com/azure-cli@sha256:0df3dcd6f4342770c2f0992c6c6552297fe8433195372fc2438a7c00bf3fd826` |
| 표본 | 4 scenarios × 3 runs × 5 Pods = 12 raw JSON, 60 Ready Pods |
| p95 | nearest-rank, 보간 없음 |
| 비교 기준 | `vn2-ondemand` median / candidate median |

## 측정 결과

| Scenario | Ready / 실패 / timeout | Pod create→ready median / p95 (ms) | Batch first-ready median / p95 (ms) | Batch all-ready median / p95 (ms) | Pod ratio | Batch ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `aks-nap` | 15 / 0 / 0 | 84,590.3 / 84,627.1 | 85,100.8 / 85,613.0 | 85,613.0 / 85,635.4 | 0.620x | 0.635x |
| `vn2-ondemand` | 15 / 0 / 0 | 52,422.3 / 151,688.0 | 38,615.2 / 55,725.5 | 54,383.4 / 152,822.5 | baseline | baseline |
| `vn2-standby` | 15 / 0 / 0 | 8,216.7 / 20,889.1 | 5,858.3 / 6,054.3 | 21,153.3 / 21,779.7 | 6.380x | 2.571x |
| `vn2-standby-cached` | 15 / 0 / 0 | 5,431.7 / 8,096.8 | 5,807.2 / 6,496.9 | 8,067.0 / 9,001.8 | 9.651x | 6.741x |

Ratio가 1보다 크면 해당 candidate median이 VN2 OnDemand보다 빠르고, 1보다 작으면 느립니다. `aks-nap`은 warm AKS 값이 아니라 VM allocation, bootstrap, node registration, image pull과 container start를 포함한 scale-out 전체 경로입니다.

## Lifecycle과 운영 evidence

- **NAP 0→1→0:** 세 run 모두 시작 전과 종료 후 NAP node 및 NodeClaim이 0이었습니다. 각 run의 5개 Pod는 하나의 새 NAP node에서 Ready가 되었고, consolidation 뒤 다시 0으로 돌아왔습니다.
- **StandbyPool:** `vn2-standby` 세 run 모두 전후 health가 `healthy`이고 `running=5`였습니다.
- **Cache 통제 조건:** cache request Pod가 `Running`인 상태에서 pool을 **5→0→5**로 deterministic recycle했고, `running=0`과 다시 `healthy`, `running=5`를 확인한 뒤 cached runs를 실행했습니다.
- **실패와 timeout:** 12 runs, 60 Pods 모두 Ready였으며 `failed_count=0`, `timeout_count=0`입니다.
- **fallback evidence:** 보존된 StandbyPool 전후 checks가 모두 `healthy`, `running=5`였으므로 fallback condition은 나타나지 않았습니다. 이 판단은 해당 health/capacity evidence 범위에 한정됩니다.
- **VN2 OnDemand ACI inventory disclosure:** The 2026-08-23 OnDemand run's ACI inventory diagnostic was not captured because `--resource-group` was omitted, so each `az-container-list.json` was a skip placeholder. Kubernetes and raw benchmark evidence show VN2 OnDemand routing and 15 Ready Pods, but that evidence does not substitute for the missing ACI inventory.

## 해석 제한

이 값은 특정 날짜, region, SKU, image, capacity 조건에서 얻은 **reference** 기술 통계이며 제품 성능 보장이나 **SLA가 아닙니다**. Azure capacity, image 상태, 네트워크와 플랫폼 버전에 따라 달라질 수 있습니다. 원본 정밀도와 machine-readable contract는 [reference JSON](./korea-central-2026-08-23.json)에 있습니다.
