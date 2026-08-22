# Module 04. 기준선과 OnDemand 측정 실행

## 목표

같은 benchmark Pod template로 `aks` 와 `vn2-ondemand` 시나리오를 실행해 기준선과 net-new ACI provisioning 경로의 차이를 raw evidence로 남깁니다.

## 예상 소요 시간

25분

## 시작 전 상태

- Module 03에서 세 경로(`aks`, `ondemand`, `standby`)가 모두 준비되었다.
- `results/` 디렉터리를 비우거나 새 timestamp 하위 경로를 만들 준비가 되었다.
- 참가자가 timeout, failure, diagnostics 증거를 삭제하지 않기로 동의했다.

## 진행 순서

1. benchmark template이 pinned digest를 가리키는지 확인합니다.
2. `aks` 시나리오를 3회 실행해 일반 AKS 노드의 Pod 시작 지연을 기록합니다.
3. `vn2-ondemand` 시나리오를 3회 실행해 net-new ACI 경로를 기록합니다.
4. 각 run 뒤에 namespace 삭제와 진단 파일 생성 여부를 확인합니다.
5. raw JSON 파일 이름 규칙이 `results/raw/<scenario>-run-<n>.json` 형태인지 검토합니다.

```bash
cd ~/aci-vn2-performance-workshop
grep -n 'mcr.microsoft.com/azure-cli@sha256:' manifests/benchmark-pod-template.yaml
./scripts/run-benchmark.sh --scenario aks --runs 3 --output-dir results
./scripts/run-benchmark.sh --scenario vn2-ondemand --runs 3 --output-dir results
find results/raw -maxdepth 1 -type f | sort
find results/diagnostics -maxdepth 2 -type f | sort | head
```

일반 AKS 노드는 첫 run만 cold image일 수 있고 두 번째 이후 run은 node image cache 덕분에 더 빨라질 수 있습니다. 이 워크숍은 그 차이를 숨기지 않으므로 run별 JSON을 그대로 보존합니다.

OnDemand 경로는 standby capacity가 없는 상태이므로 ACI provisioning, image pull, admission controller 경로가 모두 포함됩니다. 실패나 timeout이 나와도 raw JSON과 diagnostics를 남긴 뒤 다음 조치 여부를 판단합니다.

## 완료 체크포인트

- `results/raw/aks-run-1.json` 부터 `results/raw/aks-run-3.json` 까지 생성되었다.
- `results/raw/vn2-ondemand-run-1.json` 부터 `results/raw/vn2-ondemand-run-3.json` 까지 생성되었다.
- 각 run마다 diagnostics 파일이 남았는지 확인했다.
- timeout 또는 failure sample을 삭제하지 않고 유지했다.
- 다음 모듈에서 standby 시나리오를 시작할 수 있도록 현재 pool 상태를 다시 확인할 준비가 되었다.

## 이전/다음

- 이전: [Module 03](./03-install-dual-vn2.md)
- 다음: [Module 05](./05-standby-cache-benchmark.md)
