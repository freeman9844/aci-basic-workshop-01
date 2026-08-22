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

1. 현재 shell 변수와 interactive-safe helper를 준비합니다.
2. standby pool이 healthy/running 5인지 다시 확인하고 exit code를 기록합니다.
3. `vn2-standby-uncached` 를 `--runs 3` 으로 실행합니다.
4. raw JSON과 diagnostics 경로를 확인합니다.
5. `vn2-image-cache` namespace를 만들고 `manifests/image-cache-pod.yaml` 을 적용합니다.
6. standby pool을 `--max-ready-capacity 0` / `--refill-policy always` 로 내리고 running 0을 확인합니다.
7. standby pool을 다시 `--max-ready-capacity 5` / `--refill-policy always` 로 올리고 running 5를 확인합니다.
8. `vn2-standby-cached` 를 `--runs 3` 으로 실행하고, retry/archive 규칙과 image cache 해석 원칙을 정리합니다.

### 1) 현재 shell 변수와 helper 준비

```bash
cd ~/aci-vn2-performance-workshop

require_workshop_vars() {
  if [[ -z "${RG:-}" ]]; then
    printf 'RG is not set. Keep this Cloud Shell open and recover it from Module 02 before continuing.\n' >&2
    return 1
  fi
  if [[ -z "${STANDBY_POOL:-}" ]]; then
    printf 'STANDBY_POOL is not set. Keep this Cloud Shell open and recover it from Module 03 before continuing.\n' >&2
    return 1
  fi
  printf 'RG=%s\nSTANDBY_POOL=%s\n' "$RG" "$STANDBY_POOL"
}

run_and_capture_rc() {
  local label="$1"
  shift
  "$@"
  local rc=$?
  printf '%s exit code: %s\n' "$label" "$rc"
  return "$rc"
}

archive_failed_attempts() {
  local scenario="$1"
  local timestamp archive_dir
  timestamp="$(date +%Y%m%d-%H%M%S)"
  archive_dir="results/failed-attempts/${scenario}-${timestamp}"
  mkdir -p "$archive_dir/raw" "$archive_dir/diagnostics"

  mapfile -t raw_matches < <(find results/raw -maxdepth 1 -type f -name "${scenario}-run-*.json" | sort)
  mapfile -t diag_matches < <(find results/diagnostics -maxdepth 1 -mindepth 1 -type d -name "${scenario}-run-*" | sort)

  if [[ "${#raw_matches[@]}" -eq 0 && "${#diag_matches[@]}" -eq 0 ]]; then
    printf 'No prior artifacts found for %s; nothing to archive.\n' "$scenario"
    return 0
  fi

  if [[ "${#raw_matches[@]}" -gt 0 ]]; then
    mv "${raw_matches[@]}" "$archive_dir/raw/"
  fi
  if [[ "${#diag_matches[@]}" -gt 0 ]]; then
    mv "${diag_matches[@]}" "$archive_dir/diagnostics/"
  fi

  printf 'Archived prior %s artifacts to %s\n' "$scenario" "$archive_dir"
}

check_pool_state() {
  local label="$1"
  local expect_running="$2"

  run_and_capture_rc "$label" \
    ./scripts/check-standby-pool.sh -g "$RG" -n "$STANDBY_POOL" \
      --expect-running "$expect_running" --timeout-seconds 1200 --interval-seconds 15
  POOL_RC=$?

  case "$POOL_RC" in
    0)
      printf '%s succeeded.\n' "$label"
      ;;
    2)
      printf 'RC=2 means the standby pool reported degraded health.\n' >&2
      printf 'Treat the JSON output as evidence, keep this Cloud Shell open, recover the pool, and rerun the same check.\n' >&2
      ;;
    3)
      printf 'RC=3 means the standby pool did not reach the expected running count before timeout.\n' >&2
      printf 'Treat the JSON output as evidence, keep this Cloud Shell open, wait for recycle/refill or troubleshoot, and rerun the same check.\n' >&2
      ;;
    *)
      printf '%s returned unexpected RC=%s\n' "$label" "$POOL_RC" >&2
      ;;
  esac

  return "$POOL_RC"
}

mkdir -p results
require_workshop_vars
```

여기서도 persistent errexit 설정을 켜지 않습니다. `check-standby-pool.sh` 의 exit code `2/3` 는 pool health/recovery evidence이며, shell 자체를 잃어버릴 이유가 아닙니다.

helper 재사용 형태는 아래와 같습니다.

```bash
check_pool_state "standby healthy check" 5
check_pool_state "standby recycle-to-zero check" 0
check_pool_state "standby refill check" 5
```

### 2) healthy standby 5 확인

```bash
check_pool_state "standby healthy check" 5
```

표준 명령은 다음과 같습니다.

```bash
./scripts/check-standby-pool.sh -g "$RG" -n "$STANDBY_POOL" \
  --expect-running 5 --timeout-seconds 1200 --interval-seconds 15
```

이 체크가 성공해야 uncached run을 시작할 수 있습니다. standby fallback 해석을 위해서도 시작 시점의 pool health를 먼저 확보해야 합니다.

### 3) uncached standby 3회 실행

```bash
run_and_capture_rc "vn2-standby-uncached benchmark" \
  ./scripts/run-benchmark.sh \
    --scenario vn2-standby-uncached \
    --runs 3 \
    --resource-group "$RG" \
    --standby-pool "$STANDBY_POOL" \
    --output-dir results
UNCACHED_RC=$?

case "$UNCACHED_RC" in
  0)
    printf 'vn2-standby-uncached benchmark completed all 3 runs.\n'
    ;;
  2)
    printf 'RC=2 means a benchmark sample timed out or failed after raw JSON and diagnostics were written.\n' >&2
    printf 'If the collector failed after sample creation, raw JSON and diagnostics already exist for this scenario.\n' >&2
    printf 'RC=2 can also mean the internal standby pool pre-run or post-run check reported degraded health, so the current run may not have new raw JSON.\n' >&2
    printf 'Inspect any existing results/raw and results/diagnostics for this scenario, then run check_pool_state "standby healthy check" 5 (or the matching recycle/refill check) before retrying only vn2-standby-uncached.\n' >&2
    ;;
  3)
    printf 'RC=3 means the internal standby pool did not reach the expected running count before timeout during the pre-run or post-run check.\n' >&2
    printf 'Preserve this Cloud Shell session, run check_pool_state "standby healthy check" 5 (or the matching recycle/refill check), recover/refill the pool, archive only any paths that actually exist for this scenario, and then retry only vn2-standby-uncached.\n' >&2
    ;;
  *)
    printf 'Unexpected vn2-standby-uncached benchmark failure RC=%s\n' "$UNCACHED_RC" >&2
    ;;
esac
```

이 단계는 warm standby 인스턴스는 있지만 benchmark image cache가 아직 없는 상태를 측정합니다. raw evidence를 남긴 뒤 cached 단계와 직접 비교할 수 있어야 합니다.

### 4) uncached raw evidence와 diagnostics 확인

```bash
find results/raw -maxdepth 1 -type f -name 'vn2-standby-uncached-run-*.json' | sort
jq -r '.pods[] | [.name, .terminal_state, .create_to_ready_ms, .node_name] | @tsv' results/raw/vn2-standby-uncached-run-1.json
jq '{scenario, run, batch: {first_ready_ms: .batch.first_ready_ms, all_ready_ms: .batch.all_ready_ms}}' results/raw/vn2-standby-uncached-run-1.json
find results/diagnostics -maxdepth 2 -type f -path '*/vn2-standby-uncached-run-*/*' | sort
```

`results/diagnostics/vn2-standby-uncached-run-1/` 아래에는 `kubectl-describe-pods.txt`, `kubectl-events.txt`, `kubectl-nodes.json`, `az-container-list.json` 이 남습니다. standby scenario에서는 `--resource-group "$RG"` 를 넘겼으므로 `az-container-list.json` 에 실제 ACI container group inventory가 기록되는 점이 Module 04와 다릅니다.

### 5) image cache 요청 namespace와 Pod 적용

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

### 6) pool을 0으로 낮춰 uncached UVM set 제거

```bash
az standby-container-group-pool update \
  -g "$RG" -n "$STANDBY_POOL" \
  --max-ready-capacity 0 \
  --refill-policy always

run_and_capture_rc "standby recycle-to-zero check" \
  ./scripts/check-standby-pool.sh -g "$RG" -n "$STANDBY_POOL" \
    --expect-running 0 --timeout-seconds 1200 --interval-seconds 15
POOL_RC=$?

case "$POOL_RC" in
  0)
    printf 'standby recycle-to-zero check succeeded.\n'
    ;;
  2)
    printf 'RC=2 means the standby pool reported degraded health.\n' >&2
    ;;
  3)
    printf 'RC=3 means the standby pool did not reach the expected running count before timeout.\n' >&2
    ;;
  *)
    printf 'Unexpected recycle-to-zero RC=%s\n' "$POOL_RC" >&2
    ;;
esac
```

이 단계가 deterministic pool recycle 의 핵심입니다. running 0을 실제로 확인해야 Scenario C에서 사용한 uncached UVM set이 내려갔음을 주장할 수 있습니다.

### 7) pool을 5로 복구해 cached standby 준비

```bash
az standby-container-group-pool update \
  -g "$RG" -n "$STANDBY_POOL" \
  --max-ready-capacity 5 \
  --refill-policy always

run_and_capture_rc "standby refill check" \
  ./scripts/check-standby-pool.sh -g "$RG" -n "$STANDBY_POOL" \
    --expect-running 5 --timeout-seconds 1200 --interval-seconds 15
POOL_RC=$?

case "$POOL_RC" in
  0)
    printf 'standby refill check succeeded.\n'
    ;;
  2)
    printf 'RC=2 means the standby pool reported degraded health.\n' >&2
    ;;
  3)
    printf 'RC=3 means the standby pool did not reach the expected running count before timeout.\n' >&2
    ;;
  *)
    printf 'Unexpected refill RC=%s\n' "$POOL_RC" >&2
    ;;
esac
```

image-cache 요청 Pod를 유지한 상태에서 새 standby 5개를 채우면, Scenario D는 Scenario C의 uncached UVM set을 재사용하지 않고 새로 채워진 ready 인스턴스 위에서 시작합니다. running 5 after recycle proves refill capacity, not by itself that image caching finished. Use the per-run JSON and diagnostics to judge whether image caching actually helped.

### 8) cached standby 3회 실행과 retry/archive 규칙

```bash
run_and_capture_rc "vn2-standby-cached benchmark" \
  ./scripts/run-benchmark.sh \
    --scenario vn2-standby-cached \
    --runs 3 \
    --resource-group "$RG" \
    --standby-pool "$STANDBY_POOL" \
    --output-dir results
CACHED_RC=$?

case "$CACHED_RC" in
  0)
    printf 'vn2-standby-cached benchmark completed all 3 runs.\n'
    ;;
  2)
    printf 'RC=2 means a benchmark sample timed out or failed after raw JSON and diagnostics were written.\n' >&2
    printf 'If the collector failed after sample creation, raw JSON and diagnostics already exist for this scenario.\n' >&2
    printf 'RC=2 can also mean the internal standby pool pre-run or post-run check reported degraded health, so the current run may not have new raw JSON.\n' >&2
    printf 'Inspect any existing results/raw and results/diagnostics for this scenario, then run check_pool_state "standby healthy check" 5 (or the matching recycle/refill check) before retrying only vn2-standby-cached.\n' >&2
    ;;
  3)
    printf 'RC=3 means the internal standby pool did not reach the expected running count before timeout during the pre-run or post-run check.\n' >&2
    printf 'Preserve this Cloud Shell session, run check_pool_state "standby healthy check" 5 (or the matching recycle/refill check), recover/refill the pool, archive only any paths that actually exist for this scenario, and then retry only vn2-standby-cached.\n' >&2
    ;;
  *)
    printf 'Unexpected vn2-standby-cached benchmark failure RC=%s\n' "$CACHED_RC" >&2
    ;;
esac
```

같은 시나리오를 다시 실행하면 `results/raw/<scenario>-run-*` 와 `results/diagnostics/<scenario>-run-*` 고정 경로가 덮어써집니다. retry 전에 반드시 archive 하십시오.

Run the archive/rerun example only for the standby scenario that failed. Do not archive or rerun a standby scenario that already succeeded.

```bash
# Example: rerun only the failed standby scenario after evidence review and any pool recovery.
# Uncomment one block, not both.

# If vn2-standby-uncached failed:
# archive_failed_attempts vn2-standby-uncached
# ./scripts/run-benchmark.sh \
#   --scenario vn2-standby-uncached \
#   --runs 3 \
#   --resource-group "$RG" \
#   --standby-pool "$STANDBY_POOL" \
#   --output-dir results

# If vn2-standby-cached failed:
# archive_failed_attempts vn2-standby-cached
# ./scripts/run-benchmark.sh \
#   --scenario vn2-standby-cached \
#   --runs 3 \
#   --resource-group "$RG" \
#   --standby-pool "$STANDBY_POOL" \
#   --output-dir results
```

cached raw evidence는 다음과 같이 확인합니다.

```bash
find results/raw -maxdepth 1 -type f -name 'vn2-standby-cached-run-*.json' | sort
jq -r '.pods[] | [.name, .terminal_state, .create_to_ready_ms, .node_name] | @tsv' results/raw/vn2-standby-cached-run-1.json
jq '{scenario, run, batch: {first_ready_ms: .batch.first_ready_ms, all_ready_ms: .batch.all_ready_ms}}' results/raw/vn2-standby-cached-run-1.json
find results/diagnostics -maxdepth 2 -type f -path '*/vn2-standby-cached-run-*/*' | sort
```

Scenario C와 Scenario D를 비교할 때는 숫자만 보지 말고 pool recycle evidence도 함께 보관합니다. 즉, healthy 5 확인, running 0 확인, 다시 running 5 확인, 그리고 per-run raw/diagnostics를 함께 읽어야 합니다.

## 완료 체크포인트

- `./scripts/check-standby-pool.sh -g "$RG" -n "$STANDBY_POOL" --expect-running 5 --timeout-seconds 1200 --interval-seconds 15` 의 exit code를 기록했다.
- `./scripts/run-benchmark.sh --scenario vn2-standby-uncached --runs 3 --resource-group "$RG" --standby-pool "$STANDBY_POOL" --output-dir results` 와 `./scripts/run-benchmark.sh --scenario vn2-standby-cached --runs 3 --resource-group "$RG" --standby-pool "$STANDBY_POOL" --output-dir results` 의 exit code를 기록했다.
- `kubectl apply -f manifests/image-cache-pod.yaml` 후 `kubectl get pod -n vn2-image-cache vn2-benchmark-image-cache -o yaml` 로 request object를 확인했다.
- `az standby-container-group-pool update -g "$RG" -n "$STANDBY_POOL" --max-ready-capacity 0 --refill-policy always` 뒤에 running 0 체크 결과를 기록했다.
- `az standby-container-group-pool update -g "$RG" -n "$STANDBY_POOL" --max-ready-capacity 5 --refill-policy always` 뒤에 running 5 체크 결과를 기록했다.
- 두 standby 시나리오 명령이 모두 0으로 끝났을 때만 정확히 6개의 standby raw 파일을 기대합니다.
- Module 04와 Module 05의 네 시나리오 명령이 모두 0으로 끝났을 때만 정확히 12개의 전체 raw 파일을 기대합니다.
- `results/diagnostics/vn2-standby-uncached-run-1/` 와 `results/diagnostics/vn2-standby-cached-run-1/` 아래 evidence를 지우지 않고 보존했다.
- retry 전에 `results/failed-attempts/` 로 기존 evidence를 archive 하는 절차를 준비했다.
- deterministic pool recycle 덕분에 Scenario C의 uncached UVM set이 Scenario D에 재사용되지 않았음을 설명할 수 있다.

## 문제 해결

| 증상 | 원인 후보 | 확인 명령 | 조치 |
| --- | --- | --- | --- |
| 시작 전 healthy 5가 되지 않는다 | standby pool degraded 또는 refill 지연 | `./scripts/check-standby-pool.sh -g "$RG" -n "$STANDBY_POOL" --expect-running 5 --timeout-seconds 1200 --interval-seconds 15`, `az standby-container-group-pool status -g "$RG" -n "$STANDBY_POOL" --version latest --output json` | `RC=2/3` 를 evidence로 보고 shell을 유지한 채 복구 후 같은 check를 다시 실행 |
| `vn2-standby-uncached` 또는 `vn2-standby-cached` 가 `RC=2` 로 끝난다 | collector sample failure 뒤 evidence가 생겼거나, 내부 standby pool pre/post check 가 degraded 를 보고함 | `find results/raw -maxdepth 1 -type f -name 'vn2-standby-*-run-*.json' | sort`, `find results/diagnostics -maxdepth 2 -type f -path '*/vn2-standby-uncached-run-*/*' | sort`, `check_pool_state "standby healthy check" 5` | 현재 run raw 가 없을 수도 있으므로 기존 evidence부터 본다. pool 이 degraded 면 복구 후 다시 확인하고, `archive_failed_attempts <scenario>` 는 실제로 존재하는 경로에만 적용한 뒤 실패한 standby 시나리오만 다시 실행 |
| `vn2-standby-uncached` 또는 `vn2-standby-cached` 가 `RC=3` 로 끝난다 | 내부 standby pool pre-run 또는 post-run check 가 timeout 전에 expected running count 에 도달하지 못함 | `check_pool_state "standby healthy check" 5`, `check_pool_state "standby recycle-to-zero check" 0`, `check_pool_state "standby refill check" 5`, `az standby-container-group-pool status -g "$RG" -n "$STANDBY_POOL" --version latest --output json` | shell 을 유지한 채 pool recovery/refill 상태를 먼저 해결한다. 그 후 실제로 존재하는 raw/diagnostics 경로만 archive 하고 실패한 standby 시나리오만 다시 실행 |
| running 5 확인 뒤에도 cached run 해석이 애매하다 | ready capacity는 복구됐지만 image caching 완료 여부는 별도 증거가 필요함 | `jq '{scenario, run, batch}' results/raw/vn2-standby-cached-run-1.json`, `cat results/diagnostics/vn2-standby-cached-run-1/az-container-list.json`, `sed -n '1,160p' results/diagnostics/vn2-standby-cached-run-1/kubectl-events.txt` | running 5는 capacity/refill 확인으로만 쓰고, image caching 효과는 per-run JSON과 diagnostics로 판단 |

## 이전/다음

- 이전: [Module 04](./04-baseline-ondemand-benchmark.md)
- 다음: [Module 06](./06-analyze-results.md)
