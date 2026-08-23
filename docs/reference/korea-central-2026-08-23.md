# Korea Central 실제 리허설 참고 결과

이 문서는 2026-08-23에 Korea Central에서 워크숍 전체를 실제 실행한 결과입니다. 참가자의 측정 결과를 해석할 때 비교 가능한 **참고 표본**이며 SLA, 제품 성능 보장 또는 모든 구독과 시점에서의 기대값이 아닙니다.

## 실행 환경

| 항목 | 값 |
| --- | --- |
| Kubernetes | 1.34.9 |
| AKS node | `Standard_D16s_v5` 1대 |
| VN2 Helm chart | `1.3410.26081102` |
| Standby ready capacity | 5 |
| 반복 조건 | 시나리오당 5 Pods × 3회 |
| 전체 결과 | 12 runs, 60/60 Pods Ready, 실패 0, timeout 0 |

## 측정 결과

| 시나리오 | Pod create→ready Median | Pod p95 | Batch first-ready Median | Batch all-ready Median | OnDemand 대비 Pod | OnDemand 대비 Batch |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| AKS | 1,352.2 ms | 6,356.7 ms | 1,690.6 ms | 2,149.3 ms | - | - |
| VN2 OnDemand | 53,850.8 ms | 57,387.8 ms | 40,441.8 ms | 57,067.7 ms | 기준 | 기준 |
| Standby uncached | 6,942.5 ms | 20,341.5 ms | 5,336.5 ms | 20,141.3 ms | 7.757× | 2.833× |
| Standby cached | 5,497.1 ms | 18,859.0 ms | 6,260.9 ms | 8,081.5 ms | 9.796× | 7.062× |

Image Cache 적용 후 uncached 대비 Pod median은 1.263배, Batch all-ready median은 2.492배 빨라졌습니다. 이번 표본에서는 cached의 first-ready가 uncached보다 느렸지만 전체 5개 Pod 완료 시간은 크게 줄었습니다. 따라서 한 개 Pod의 첫 응답과 burst 전체 완료 시간을 분리해서 해석해야 합니다.

## 리허설에서 확인한 운영상 주의사항

- 이전 8-vCPU node 한 대는 두 VN2 infrastructure release와 500m benchmark Pod 5개를 동시에 수용하지 못했습니다. 성공 리허설과 현재 워크숍 기본값은 `Standard_D16s_v5`입니다.
- benchmark manifest는 반드시 각 run namespace에 적용해야 합니다. 현재 collector는 `kubectl apply --namespace <run namespace>`를 사용합니다.
- cached 측정 전 Image Cache Pod를 만든 뒤 Standby Pool ready capacity를 5→0→5로 recycle하고, `running=5` 복구를 확인해야 합니다.
- 종료 시 `az group exists --name "$RG"`가 `false`인지 확인해야 과금 리소스 정리가 완료된 것입니다.

기계 판독 가능한 원본 참고값은 [`korea-central-2026-08-23.json`](./korea-central-2026-08-23.json)에 있습니다.
