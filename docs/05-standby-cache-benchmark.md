# Module 05. StandbyPool과 Image Cache 측정 실행

## 목표

StandbyPool에서 uncached run을 먼저 수행한 뒤 image cache를 적용하고 pool을 재순환시켜 `vn2-standby-uncached` 와 `vn2-standby-cached` 차이를 비교 가능한 raw evidence로 남깁니다.

## 예상 소요 시간

25분

## 시작 전 상태

- Module 04까지 완료되어 `aks` 와 `vn2-ondemand` 결과가 이미 존재한다.
- standby pool 이름과 resource group 이름이 확정되어 있다.
- pool health가 healthy이며 ready capacity 5를 다시 채울 수 있는 quota가 남아 있다.

## 진행 순서

1. standby pool이 healthy/running 5인지 확인합니다.
2. `vn2-standby-uncached` 시나리오를 3회 실행합니다.
3. image cache 요청 Pod를 standby 경로에 배치합니다.
4. 기존 uncached warm UVM이 남지 않도록 ready capacity를 0까지 낮춘 뒤 다시 5로 올립니다.
5. pool refresh 후 `vn2-standby-cached` 시나리오를 3회 실행합니다.

```bash
cd ~/aci-vn2-performance-workshop
./scripts/check-standby-pool.sh -g "$WORKSHOP_RG" -n "$STANDBY_POOL_NAME" --expect-running 5 --timeout-seconds 1200 --interval-seconds 15
./scripts/run-benchmark.sh --scenario vn2-standby-uncached --runs 3 --resource-group "$WORKSHOP_RG" --standby-pool "$STANDBY_POOL_NAME" --output-dir results
kubectl apply -f manifests/image-cache-pod.yaml
az standby-container-group-pool update --resource-group "$WORKSHOP_RG" --name "$STANDBY_POOL_NAME" --max-ready-capacity 0
./scripts/check-standby-pool.sh -g "$WORKSHOP_RG" -n "$STANDBY_POOL_NAME" --expect-running 0 --timeout-seconds 1200 --interval-seconds 15
az standby-container-group-pool update --resource-group "$WORKSHOP_RG" --name "$STANDBY_POOL_NAME" --max-ready-capacity 5
./scripts/check-standby-pool.sh -g "$WORKSHOP_RG" -n "$STANDBY_POOL_NAME" --expect-running 5 --timeout-seconds 1200 --interval-seconds 15
./scripts/run-benchmark.sh --scenario vn2-standby-cached --runs 3 --resource-group "$WORKSHOP_RG" --standby-pool "$STANDBY_POOL_NAME" --output-dir results
```

핵심은 cached run 전에 pool을 재순환시켜 uncached warm instance를 제거하는 것입니다. 그렇지 않으면 cached와 uncached 경로가 섞여 실습 결과 해석이 어려워집니다.

## 완료 체크포인트

- `vn2-standby-uncached` 3회 결과가 raw JSON으로 저장되었다.
- image cache 요청 Pod가 적용되었다.
- standby pool을 0으로 내렸다가 5로 복구하는 과정이 기록되었다.
- `vn2-standby-cached` 3회 결과가 raw JSON으로 저장되었다.
- standby fallback 여부를 나중에 분석할 수 있도록 pool health evidence를 남겼다.

## 이전/다음

- 이전: [Module 04](./04-baseline-ondemand-benchmark.md)
- 다음: [Module 06](./06-analyze-results.md)
