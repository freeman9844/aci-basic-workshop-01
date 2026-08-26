# 선택 사항: 과거 성능 benchmark

> 이 문서는 operator가 과거의 반복 측정 자산을 재사용할 때만 참고합니다. 120분 hands-on workshop에 필요하지 않습니다.

## active workshop과의 경계

- active workshop은 VN2 경로별 Pod 1개를 한 번 관찰합니다.
- 이 appendix만 5 Pods × 3 runs, median, p95, batch timing, speed-up ratio를 다룹니다.
- 과거 결과는 특정 시점과 구독의 관찰값이며 성능 보장 또는 SLA가 아닙니다.

## 보존된 도구

- [`run-benchmark.sh`](../../scripts/run-benchmark.sh)
- [`collect-pod-latency.py`](../../scripts/collect-pod-latency.py)
- [`summarize-results.py`](../../scripts/summarize-results.py)
- [`check-nap-capacity.sh`](../../scripts/check-nap-capacity.sh)
- [`benchmark-pod-template.yaml`](../../manifests/benchmark-pod-template.yaml)
- [`nap-workshop-template.yaml`](../../manifests/nap-workshop-template.yaml)

## historical scenarios

`aks-nap`, `vn2-ondemand`, `vn2-standby`, `vn2-standby-cached`

## Korea Central historical reference

- [Markdown](../reference/korea-central-2026-08-23.md)
- [JSON](../reference/korea-central-2026-08-23.json)

## retained commands

이 appendix는 다음 retained command interface만 보존합니다.

```bash
./scripts/run-benchmark.sh --scenario aks-nap --runs 3 --output-dir results
./scripts/run-benchmark.sh --scenario vn2-ondemand --runs 3 --output-dir results
./scripts/run-benchmark.sh --scenario vn2-standby --runs 3 --resource-group "$RG" --standby-pool "$STANDBY_POOL" --output-dir results
./scripts/run-benchmark.sh --scenario vn2-standby-cached --runs 3 --resource-group "$RG" --standby-pool "$STANDBY_POOL" --output-dir results
python3 scripts/summarize-results.py --input results/raw --output-dir results
```

이 명령들은 참가자 모듈 흐름에 연결하지 않고, historical appendix에서만 참조합니다.
