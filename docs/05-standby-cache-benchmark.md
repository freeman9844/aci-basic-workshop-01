# Module 05. StandbyPool과 Image Cache 측정 실행

## 목표

`vn2-standby-uncached` 를 먼저 측정한 뒤 `manifests/image-cache-pod.yaml` 을 `vn2-image-cache` namespace에 적용하고 standby pool을 deterministic pool recycle 방식으로 0 → 5로 재구성해 `vn2-standby-cached` 를 다시 측정합니다. 이렇게 해야 Scenario C의 uncached UVM set이 Scenario D에 재사용되지 않았음을 설명할 수 있습니다.

## 예상 소요 시간

25분

## 시작 전 상태

- Module 03에서 export 한 같은 `$RG` 와 `$STANDBY_POOL` 이 현재 Cloud Shell 세션에 남아 있다.
- standby virtual node 와 standby pool이 healthy 상태이며 ready capacity 5를 다시 채울 quota가 있다.
- Module 04 결과가 이미 `results/raw/` 와 `results/diagnostics/` 아래에 보관되어 있다.
- 실패나 timeout evidence를 삭제하지 않겠다는 원칙을 유지한다.

## 진행 순서

1. standby pool이 healthy/running 5인지 다시 확인합니다.
2. `vn2-standby-uncached` 를 `--runs 3` 으로 실행합니다.
3. raw JSON과 diagnostics 경로를 확인합니다.
4. `vn2-image-cache` namespace를 만들고 `manifests/image-cache-pod.yaml` 을 적용합니다.
5. image-cache Pod YAML로 request object를 증명합니다.
6. standby pool을 `--max-ready-capacity 0` / `--refill-policy always` 로 내리고 running 0을 기다립니다.
7. standby pool을 다시 `--max-ready-capacity 5` / `--refill-policy always` 로 올리고 running 5를 기다립니다.
8. `vn2-standby-cached` 를 `--runs 3` 으로 실행하고, deterministic pool recycle 덕분에 Scenario C UVM set 재사용이 차단되었음을 설명합니다.

### 1) 현재 shell 변수와 healthy standby 5 확인

```bash
cd ~/aci-vn2-performance-workshop

set -euo pipefail

: "${RG:?Keep the same resource group from Module 02.}"
: "${STANDBY_POOL:?Keep the standby pool exported in Module 03.}"

./scripts/check-standby-pool.sh -g "$RG" -n "$STANDBY_POOL" \
  --expect-running 5 --timeout-seconds 1200 --interval-seconds 15
```

이 체크가 성공해야 uncached run을 시작할 수 있습니다. standby fallback 해석을 위해서도 시작 시점의 pool health를 먼저 확보해야 합니다.

### 2) uncached standby 3회 실행

```bash
./scripts/run-benchmark.sh \
  --scenario vn2-standby-uncached \
  --runs 3 \
  --resource-group "$RG" \
  --standby-pool "$STANDBY_POOL" \
  --output-dir results
```

이 단계는 warm standby 인스턴스는 있지만 benchmark image cache가 아직 없는 상태를 측정합니다. raw evidence를 남긴 뒤 cached 단계와 직접 비교할 수 있어야 합니다.

### 3) uncached raw evidence와 diagnostics 확인

```bash
find results/raw -maxdepth 1 -type f -name 'vn2-standby-uncached-run-*.json' | sort
jq -r '.pods[] | [.name, .terminal_state, .create_to_ready_ms, .node_name] | @tsv' results/raw/vn2-standby-uncached-run-1.json
jq '{scenario, run, batch: {first_ready_ms: .batch.first_ready_ms, all_ready_ms: .batch.all_ready_ms}}' results/raw/vn2-standby-uncached-run-1.json
find results/diagnostics -maxdepth 2 -type f -path '*/vn2-standby-uncached-run-*/*' | sort
```

`results/diagnostics/vn2-standby-uncached-run-1/` 아래에는 `kubectl-describe-pods.txt`, `kubectl-events.txt`, `kubectl-nodes.json`, `az-container-list.json` 이 남습니다. standby scenario에서는 `--resource-group "$RG"` 를 넘겼으므로 `az-container-list.json` 에 실제 ACI container group inventory가 기록되는 점이 Module 04와 다릅니다.

### 4) image cache 요청 namespace와 Pod 적용

```bash
kubectl create namespace vn2-image-cache --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f manifests/image-cache-pod.yaml
kubectl get pod -n vn2-image-cache vn2-benchmark-image-cache -o yaml
```

여기서 `vn2-benchmark-image-cache` 는 benchmark sample이 아니라 request/template input 입니다. 이 Pod 자체를 latency sample로 세지 않고, `microsoft.containerinstance.virtualnode.imagecachepod: "true"` annotation 을 가진 요청 객체로만 사용합니다.

예상 YAML에는 최소한 다음 구조가 보여야 합니다.

```text
metadata:
  name: vn2-benchmark-image-cache
  namespace: vn2-image-cache
  annotations:
    microsoft.containerinstance.virtualnode.imagecachepod: "true"
```

### 5) pool을 0으로 낮춰 uncached UVM set 제거

```bash
az standby-container-group-pool update \
  -g "$RG" -n "$STANDBY_POOL" \
  --max-ready-capacity 0 \
  --refill-policy always

./scripts/check-standby-pool.sh -g "$RG" -n "$STANDBY_POOL" \
  --expect-running 0 --timeout-seconds 1200 --interval-seconds 15
```

이 단계가 deterministic pool recycle 의 핵심입니다. running 0을 실제로 확인해야 Scenario C에서 사용한 uncached UVM set이 내려갔음을 주장할 수 있습니다.

### 6) pool을 5로 복구해 cached standby 준비

```bash
az standby-container-group-pool update \
  -g "$RG" -n "$STANDBY_POOL" \
  --max-ready-capacity 5 \
  --refill-policy always

./scripts/check-standby-pool.sh -g "$RG" -n "$STANDBY_POOL" \
  --expect-running 5 --timeout-seconds 1200 --interval-seconds 15
```

image-cache 요청 Pod를 유지한 상태에서 새 standby 5개를 채우면, Scenario D는 Scenario C의 uncached UVM set을 재사용하지 않고 새로 채워진 ready 인스턴스 위에서 시작합니다.

### 7) cached standby 3회 실행

```bash
./scripts/run-benchmark.sh \
  --scenario vn2-standby-cached \
  --runs 3 \
  --resource-group "$RG" \
  --standby-pool "$STANDBY_POOL" \
  --output-dir results
```

이제 cached run의 raw JSON은 warm standby + cached image 조합을 반영합니다. 같은 `benchmark-path=standby` 경로지만, deterministic pool recycle 과 image cache request/template input 적용 여부가 Scenario C와 Scenario D를 분리합니다.

### 8) cached raw evidence와 재순환 증거 확인

```bash
find results/raw -maxdepth 1 -type f -name 'vn2-standby-cached-run-*.json' | sort
jq -r '.pods[] | [.name, .terminal_state, .create_to_ready_ms, .node_name] | @tsv' results/raw/vn2-standby-cached-run-1.json
jq '{scenario, run, batch: {first_ready_ms: .batch.first_ready_ms, all_ready_ms: .batch.all_ready_ms}}' results/raw/vn2-standby-cached-run-1.json
find results/diagnostics -maxdepth 2 -type f -path '*/vn2-standby-cached-run-*/*' | sort
```

Scenario C와 Scenario D를 비교할 때는 숫자만 보지 말고 pool recycle 증거도 함께 보관합니다. 즉, `./scripts/check-standby-pool.sh -g "$RG" -n "$STANDBY_POOL" --expect-running 5 --timeout-seconds 1200 --interval-seconds 15` 로 healthy 5를 확인한 기록, `--expect-running 0` 으로 내려간 기록, 다시 `--expect-running 5` 로 채운 기록을 모두 남겨야 합니다.

## 완료 체크포인트

- `./scripts/check-standby-pool.sh -g "$RG" -n "$STANDBY_POOL" --expect-running 5 --timeout-seconds 1200 --interval-seconds 15` 로 시작 상태를 확인했다.
- `./scripts/run-benchmark.sh --scenario vn2-standby-uncached --runs 3 --resource-group "$RG" --standby-pool "$STANDBY_POOL" --output-dir results` 가 성공했다.
- `kubectl apply -f manifests/image-cache-pod.yaml` 후 `kubectl get pod -n vn2-image-cache vn2-benchmark-image-cache -o yaml` 로 request object를 확인했다.
- `az standby-container-group-pool update -g "$RG" -n "$STANDBY_POOL" --max-ready-capacity 0 --refill-policy always` 뒤에 `./scripts/check-standby-pool.sh -g "$RG" -n "$STANDBY_POOL" --expect-running 0 --timeout-seconds 1200 --interval-seconds 15` 가 성공했다.
- `az standby-container-group-pool update -g "$RG" -n "$STANDBY_POOL" --max-ready-capacity 5 --refill-policy always` 뒤에 `./scripts/check-standby-pool.sh -g "$RG" -n "$STANDBY_POOL" --expect-running 5 --timeout-seconds 1200 --interval-seconds 15` 가 성공했다.
- `./scripts/run-benchmark.sh --scenario vn2-standby-cached --runs 3 --resource-group "$RG" --standby-pool "$STANDBY_POOL" --output-dir results` 가 성공했다.
- `find results/raw -maxdepth 1 -type f -name 'vn2-standby-uncached-run-*.json' | sort` 와 `find results/raw -maxdepth 1 -type f -name 'vn2-standby-cached-run-*.json' | sort` 로 6개 raw 파일을 확인했다.
- `results/diagnostics/vn2-standby-uncached-run-1/` 와 `results/diagnostics/vn2-standby-cached-run-1/` 아래 evidence를 지우지 않고 보존했다.
- deterministic pool recycle 덕분에 Scenario C의 uncached UVM set이 Scenario D에 재사용되지 않았음을 설명할 수 있다.

## 문제 해결

| 증상 | 원인 후보 | 확인 명령 | 조치 |
| --- | --- | --- | --- |
| 시작 전 healthy 5가 되지 않는다 | standby pool degraded 또는 quota 부족 | `./scripts/check-standby-pool.sh -g "$RG" -n "$STANDBY_POOL" --expect-running 5 --timeout-seconds 1200 --interval-seconds 15`, `az standby-container-group-pool status -g "$RG" -n "$STANDBY_POOL" --version latest --output json` | uncached run을 시작하지 말고 pool 상태를 먼저 복구 |
| image cache 요청이 보이지 않는다 | `vn2-image-cache` namespace 생성/적용 실패 | `kubectl get pod -n vn2-image-cache vn2-benchmark-image-cache -o yaml`, `kubectl get events -n vn2-image-cache --sort-by=.metadata.creationTimestamp` | YAML의 annotation, namespace, standby nodeSelector를 확인한 뒤 다시 apply |
| running 0이 되지 않는다 | 기존 standby 인스턴스가 아직 정리 중이거나 refill policy가 유지되지 않음 | `az standby-container-group-pool update -g "$RG" -n "$STANDBY_POOL" --max-ready-capacity 0 --refill-policy always`, `./scripts/check-standby-pool.sh -g "$RG" -n "$STANDBY_POOL" --expect-running 0 --timeout-seconds 1200 --interval-seconds 15` | 0 확인 전에는 cached run으로 넘어가지 않음 |
| cached run이 uncached 와 비슷하게 느리다 | deterministic pool recycle 누락, image cache request object 미적용, fallback 발생 가능성 | `find results/diagnostics -maxdepth 2 -type f -path '*/vn2-standby-cached-run-*/*' | sort`, `cat results/diagnostics/vn2-standby-cached-run-1/az-container-list.json`, `sed -n '1,160p' results/diagnostics/vn2-standby-cached-run-1/kubectl-events.txt` | pool recycle 기록과 request/template input 존재를 먼저 확인하고, raw evidence를 유지한 채 Module 06에서 fallback 가능성과 함께 해석 |

## 이전/다음

- 이전: [Module 04](./04-baseline-ondemand-benchmark.md)
- 다음: [Module 06](./06-analyze-results.md)
