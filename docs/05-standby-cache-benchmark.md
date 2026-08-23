# 05. StandbyPool과 Image Cache 측정 실행

> 기본 StandbyPool 경로와 Image Cache 적용 경로를 같은 pool에서 순서대로 측정하고, recycle/refill evidence를 보존합니다.


## 목표

이 모듈을 완료하면 다음을 할 수 있습니다.

- `results/workshop.env` 와 standby helper를 복구해 같은 `$RG` 와 `$STANDBY_POOL` 을 계속 사용할 수 있습니다.
- `vn2-standby` 와 `vn2-standby-cached` 를 같은 일반적인 pre-provisioned StandbyPool 조건에서 각각 3회 실행할 수 있습니다.
- deterministic pool recycle 기준으로 `--max-ready-capacity 5 → 0 → 5` recycle/refill과 Image Cache request를 분리해 해석할 수 있습니다.
- 실패한 standby scenario만 archive하고 필요한 recovery 순서를 지켜 재실행할 수 있습니다.

## 예상 소요 시간

30분

## 시작 전 상태

- Module 03에서 저장한 `results/workshop.env`에 같은 `$RG`와 `$STANDBY_POOL`이 들어 있다.
- standby virtual node가 Ready이고 pool을 healthy/running 5로 채울 quota가 있다.
- Module 04의 6개 성공 raw 파일 또는 실패/timeout evidence가 보존되어 있다.
- Image Cache 적용 전 기본 StandbyPool 측정을 먼저 완료한다.


## 태그 범례

| 태그 | 의미 |
|------|------|
| 🟢 **실행** | 참가자가 직접 입력하거나 수행해야 하는 단계 |
| 👁️ **설명** | 왜 이 단계를 하는지 이해하기 위한 읽기 전용 안내 |
| 📋 **예상 출력** | 실행 결과와 비교할 기준 출력 |
| ⚠️ **주의** | 비용, 순서, 안전성, 계약 조건 안내 |


## 진행 순서

1. workshop state와 interactive-safe helper를 복구합니다.
2. pool이 healthy/running 5인지 확인합니다.
3. `vn2-standby`를 3회 실행하고 refill evidence를 확인합니다.
4. Image Cache 요청 Pod를 적용합니다.
5. 같은 pool을 running 5 → 0 → 5로 recycle합니다.
6. cached run 직전에 healthy/running 5를 다시 확인합니다.
7. `vn2-standby-cached`를 3회 실행하고 실패한 scenario만 archive/retry합니다.


## 0. 세션 재연결 시 상태 복구 (선택)

<details>
<summary>fresh Cloud Shell에서 standby benchmark state 복구 명령 보기</summary>

👁️ **설명**

StandbyPool 측정은 같은 `$STANDBY_POOL` 을 계속 사용해야 해석이 맞습니다. 새 Cloud Shell에서는 state file을 다시 불러오고, 필요하면 pool health check부터 다시 시작합니다.

🟢 **실행**

```bash
cd ~/aci-vn2-performance-workshop
source results/workshop.env
printf 'RG=%s\nSTANDBY_POOL=%s\n' "$RG" "$STANDBY_POOL"
```

📋 **예상 출력**

- 같은 resource group과 standby pool 이름이 다시 보여야 합니다.
- 값이 비어 있으면 Module 03 recovery 후 2단계의 health check부터 다시 진행합니다.

</details>

👁️ **설명**

아래 단계는 설명 → 실행 → 예상 출력 → 주의 순서로 읽습니다. 코드 블록은 순서를 바꾸지 말고, fail-fast로 멈추면 같은 단계에서 원인을 먼저 정리합니다.

⚠️ **주의**

선행 조건을 확인하지 못했거나 측정 상태가 불분명하면 다음 단계로 넘어가지 않습니다.


### 1) workshop state와 helper 준비

🟢 **실행**

```bash
cd ~/aci-vn2-performance-workshop

WORKSHOP_STATE="results/workshop.env"
if [[ -f "$WORKSHOP_STATE" ]]; then
  source "$WORKSHOP_STATE"
fi

require_workshop_vars() {
  if [[ -z "${RG:-}" ]]; then
    printf 'RG is not set. Recover it from results/workshop.env or rerun the exact recovery steps from Module 02 before continuing.\n' >&2
    return 1
  fi
  if [[ -z "${STANDBY_POOL:-}" ]]; then
    printf 'STANDBY_POOL is not set. Recover it from results/workshop.env or rerun the exact recovery steps from Module 03 before continuing.\n' >&2
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
      printf 'Keep the JSON output as evidence, recover the pool, and rerun the same check.\n' >&2
      ;;
    3)
      printf 'RC=3 means the standby pool did not reach the expected running count before timeout.\n' >&2
      printf 'Keep the JSON output as evidence; wait for recycle/refill or troubleshoot before continuing.\n' >&2
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

👁️ **설명**

persistent errexit 설정은 사용하지 않습니다. pool checker와 benchmark의 exit code를 기록한 뒤 같은 shell에서 복구를 계속합니다.

🟢 **실행**

helper 호출 형태는 다음과 같습니다.

```bash
check_pool_state "standby healthy check" 5
check_pool_state "standby recycle-to-zero check" 0
check_pool_state "standby refill check" 5
check_pool_state "cached pre-run healthy check" 5
```

### 2) 기본 StandbyPool health 확인

🟢 **실행**

```bash
check_pool_state "standby healthy check" 5
```

🟢 **실행**

표준 명령은 다음과 같습니다.

```bash
./scripts/check-standby-pool.sh -g "$RG" -n "$STANDBY_POOL" \
  --expect-running 5 --timeout-seconds 1200 --interval-seconds 15
```

⚠️ **주의**

healthy/running 5가 확인되어야 기본 StandbyPool benchmark를 시작합니다. runner도 각 run 전후 같은 pool과 기대 running count를 검사하므로 capacity가 refill되지 않으면 다음 run을 시작하지 않습니다.

### 3) `vn2-standby` 3회 실행

🟢 **실행**

```bash
run_and_capture_rc "vn2-standby benchmark" \
  ./scripts/run-benchmark.sh \
    --scenario vn2-standby \
    --runs 3 \
    --resource-group "$RG" \
    --standby-pool "$STANDBY_POOL" \
    --output-dir results
STANDBY_RC=$?

case "$STANDBY_RC" in
  0)
    printf 'vn2-standby benchmark completed all 3 runs.\n'
    ;;
  2)
    printf 'RC=2 means a benchmark sample timed out or failed after raw JSON and diagnostics were written.\n' >&2
    printf 'If the collector failed after sample creation, raw JSON and diagnostics already exist for this scenario.\n' >&2
    printf 'RC=2 can also mean the internal standby pool pre-run or post-run check reported degraded health, so the current run may not have new raw JSON.\n' >&2
    printf 'Inspect existing evidence, then run check_pool_state "standby healthy check" 5 before retrying only vn2-standby.\n' >&2
    ;;
  3)
    printf 'RC=3 means the internal standby pool did not reach the expected running count before timeout during the pre-run or post-run check.\n' >&2
    printf 'If results/workshop.env was restored in a fresh Cloud Shell, run check_pool_state "standby healthy check" 5, recover/refill the pool, archive only any paths that actually exist for this scenario, and retry only vn2-standby.\n' >&2
    ;;
  *)
    printf 'Unexpected vn2-standby benchmark failure RC=%s\n' "$STANDBY_RC" >&2
    ;;
esac
```

👁️ **설명**

이 단계는 Image Cache를 별도 통제 변수로 추가하기 전, 평상시 pre-provisioned StandbyPool 경로를 측정합니다.

🟢 **실행**

```bash
find results/raw -maxdepth 1 -type f -name 'vn2-standby-run-*.json' | sort
jq -r '.pods[] | [.name, .terminal_state, .create_to_ready_ms, .node_name] | @tsv' results/raw/vn2-standby-run-1.json
jq '{scenario, run, batch: {first_ready_ms: .batch.first_ready_ms, all_ready_ms: .batch.all_ready_ms}}' results/raw/vn2-standby-run-1.json
find results/diagnostics -maxdepth 2 -type f -path '*/vn2-standby-run-*/*' | sort
```

👁️ **설명**

`results/diagnostics/vn2-standby-run-1/` 아래의 `kubectl-describe-pods.txt`, `kubectl-events.txt`, `kubectl-nodes.json`, `az-container-list.json`, `standby-precheck.json`, `standby-postcheck.json`을 보존합니다. pre/post JSON은 각 run 전후 healthy/running 5와 refill을 증명합니다.

### 4) Image Cache 요청 적용

🟢 **실행**

```bash
kubectl create namespace vn2-image-cache --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f manifests/image-cache-pod.yaml
kubectl get pod -n vn2-image-cache vn2-benchmark-image-cache -o yaml
```

👁️ **설명**

`vn2-benchmark-image-cache`는 benchmark sample이 아니라 request/template input입니다. `vn2-image-cache` namespace의 이 Pod를 latency 표본에 포함하지 않습니다.

### 5) 같은 pool을 5 → 0 → 5로 recycle

👁️ **설명**

시작 health check에서 running 5를 확인한 바로 그 `$STANDBY_POOL`을 0으로 내립니다.

🟢 **실행**

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

⚠️ **주의**

running 0이 확인되어야 기존 UVM set이 제거되었다고 판단합니다. 0에 도달하지 못하면 5로 복구하거나 cached benchmark를 시작하지 않습니다.

🟢 **실행**

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

👁️ **설명**

running 5 after recycle proves refill capacity, not by itself that image caching finished. Use the per-run JSON and diagnostics to judge whether image caching actually helped.

### 6) cached run 직전 pool health 재확인

👁️ **설명**

recycle이 끝난 뒤 다른 작업이 capacity를 소비했을 수 있으므로 cached 명령 바로 전에 같은 pool을 다시 확인합니다.

🟢 **실행**

```bash
check_pool_state "cached pre-run healthy check" 5
```

⚠️ **주의**

이 check가 0이 아니면 cached benchmark를 시작하지 않습니다.

### 7) `vn2-standby-cached` 3회 실행

🟢 **실행**

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
    printf 'Inspect existing evidence. Before retrying vn2-standby-cached, follow the cached retry phase in section 8 to re-apply the Image Cache request and recycle the same pool 5 → 0 → 5.\n' >&2
    ;;
  3)
    printf 'RC=3 means the internal standby pool did not reach the expected running count before timeout during the pre-run or post-run check.\n' >&2
    printf 'If results/workshop.env was restored in a fresh Cloud Shell, recover/refill the pool, then follow the full cached retry phase in section 8 and archive only any paths that actually exist for this scenario.\n' >&2
    printf 'A healthy running 5 alone is not sufficient cached retry preparation.\n' >&2
    ;;
  *)
    printf 'Unexpected vn2-standby-cached benchmark failure RC=%s\n' "$CACHED_RC" >&2
    ;;
esac
```

🟢 **실행**

```bash
find results/raw -maxdepth 1 -type f -name 'vn2-standby-cached-run-*.json' | sort
jq -r '.pods[] | [.name, .terminal_state, .create_to_ready_ms, .node_name] | @tsv' results/raw/vn2-standby-cached-run-1.json
jq '{scenario, run, batch: {first_ready_ms: .batch.first_ready_ms, all_ready_ms: .batch.all_ready_ms}}' results/raw/vn2-standby-cached-run-1.json
find results/diagnostics -maxdepth 2 -type f -path '*/vn2-standby-cached-run-*/*' | sort
```

📋 **예상 출력**

`results/diagnostics/vn2-standby-cached-run-1/`의 pool pre/post 상태와 ACI inventory를 recycle evidence와 함께 해석합니다.

### 8) 실패한 standby scenario만 archive하고 재실행

👁️ **설명**

Run the archive/rerun example only for the standby scenario that failed. Do not archive or rerun a standby scenario that already succeeded. Retry phase/order rule은 측정 순서와 같습니다. 두 scenario가 모두 실패했다면 `vn2-standby` retry를 먼저 끝낸 뒤 cached retry phase를 시작합니다. baseline recovery는 cache 요청을 삭제하고 uncached capacity를 다시 만들기 때문에, 모든 `vn2-standby-cached` retry는 현재 상태를 cached로 간주하지 않고 Image Cache 요청을 다시 apply한 뒤 같은 pool을 5 → 0 → 5로 recycle합니다. 각 check가 0일 때만 다음 명령으로 진행합니다.

🟢 **실행**

```bash
# Example: rerun only the failed standby scenario after evidence review and any pool recovery.

# If vn2-standby failed:
# check_pool_state "baseline retry starting healthy check" 5
# kubectl delete -f manifests/image-cache-pod.yaml --ignore-not-found=true
# az standby-container-group-pool update \
#   -g "$RG" -n "$STANDBY_POOL" \
#   --max-ready-capacity 0 \
#   --refill-policy always
# check_pool_state "baseline retry recycle-to-zero check" 0
# az standby-container-group-pool update \
#   -g "$RG" -n "$STANDBY_POOL" \
#   --max-ready-capacity 5 \
#   --refill-policy always
# check_pool_state "baseline retry refill check" 5
# check_pool_state "baseline retry pre-run healthy check" 5
```

👁️ **설명**

baseline restore check가 모두 성공한 뒤 기존 baseline evidence를 archive하고 `vn2-standby`만 다시 실행합니다. 두 scenario가 모두 실패했다면 이 baseline retry가 성공한 뒤에만 아래 cached retry phase로 이동합니다.

🟢 **실행**

```bash
# archive_failed_attempts vn2-standby
# ./scripts/run-benchmark.sh \
#   --scenario vn2-standby \
#   --runs 3 \
#   --resource-group "$RG" \
#   --standby-pool "$STANDBY_POOL" \
#   --output-dir results
```

👁️ **설명**

cached retry는 이전 cached UVM set이나 health check만 재사용하지 않습니다. baseline retry 수행 여부와 관계없이 Image Cache request를 ensure하고 같은 `$STANDBY_POOL`을 5 → 0 → 5로 다시 recycle하여 cached capacity를 rebuild합니다.

🟢 **실행**

```bash
# If vn2-standby-cached failed:
# Retry order: if both scenarios failed, finish the vn2-standby retry before starting this cached retry.
# kubectl create namespace vn2-image-cache --dry-run=client -o yaml | kubectl apply -f -
# kubectl apply -f manifests/image-cache-pod.yaml
# kubectl get pod -n vn2-image-cache vn2-benchmark-image-cache -o yaml
# check_pool_state "cached retry starting healthy check" 5
# az standby-container-group-pool update \
#   -g "$RG" -n "$STANDBY_POOL" \
#   --max-ready-capacity 0 \
#   --refill-policy always
# check_pool_state "cached retry recycle-to-zero check" 0
# az standby-container-group-pool update \
#   -g "$RG" -n "$STANDBY_POOL" \
#   --max-ready-capacity 5 \
#   --refill-policy always
# check_pool_state "cached retry refill check" 5
# check_pool_state "cached retry pre-run healthy check" 5
```

👁️ **설명**

cached rebuild check가 모두 성공한 뒤 기존 cached evidence를 archive하고 `vn2-standby-cached`만 다시 실행합니다.

🟢 **실행**

```bash
# archive_failed_attempts vn2-standby-cached
# ./scripts/run-benchmark.sh \
#   --scenario vn2-standby-cached \
#   --runs 3 \
#   --resource-group "$RG" \
#   --standby-pool "$STANDBY_POOL" \
#   --output-dir results
```

## 완료 체크포인트

- 기본 `vn2-standby` 전에 healthy/running 5를 확인했다.
- `vn2-standby`와 `vn2-standby-cached`를 각각 `--runs 3`으로 실행하고 exit code를 기록했다.
- Image Cache 요청 뒤 같은 pool의 running 5 → 0 → 5를 확인했다.
- cached run 직전에 healthy/running 5를 다시 확인했다.
- 두 standby 시나리오 명령이 모두 0으로 끝났을 때만 정확히 6개의 standby raw 파일을 기대합니다.
- Module 04와 Module 05의 네 시나리오 명령이 모두 0으로 끝났을 때만 정확히 12개의 전체 raw 파일을 기대합니다.
- `results/raw/vn2-standby-run-{1,2,3}.json`과 `results/raw/vn2-standby-cached-run-{1,2,3}.json`을 확인했다.
- `results/diagnostics/vn2-standby-run-1/`와 `results/diagnostics/vn2-standby-cached-run-1/`의 evidence를 보존했다.
- retry 전에 `results/failed-attempts/`로 기존 evidence를 archive한다.

## 문제 해결

| 증상 | 확인 | 조치 |
| --- | --- | --- |
| healthy/running 5가 되지 않는다 | `./scripts/check-standby-pool.sh -g "$RG" -n "$STANDBY_POOL" --expect-running 5 --timeout-seconds 1200 --interval-seconds 15`, `az standby-container-group-pool status -g "$RG" -n "$STANDBY_POOL" --version latest --output json` | RC=2/3 JSON을 보존하고 pool을 복구한 뒤 같은 check를 재실행 |
| `vn2-standby` 또는 `vn2-standby-cached`가 RC=2다 | `find results/raw -maxdepth 1 -type f -name 'vn2-standby*-run-*.json' \| sort`, `check_pool_state "standby healthy check" 5` | 기존 raw/diagnostics부터 확인하고 실제로 존재하는 경로만 archive한 뒤 실패한 scenario만 재실행 |
| standby scenario가 RC=3다 | `check_pool_state "standby healthy check" 5`, `check_pool_state "standby recycle-to-zero check" 0`, `check_pool_state "standby refill check" 5` | pool recovery/refill을 완료하기 전 다음 run을 시작하지 않음 |
| refill 5 뒤 cached 결과 해석이 애매하다 | `jq '{scenario, run, batch}' results/raw/vn2-standby-cached-run-1.json`, `cat results/diagnostics/vn2-standby-cached-run-1/az-container-list.json` | running 5는 capacity 증거로만 사용하고 cache 효과는 per-run JSON과 diagnostics로 판단 |

## 이전/다음

- 이전: [Module 04](./04-baseline-ondemand-benchmark.md)
- 다음: [Module 06](./06-analyze-results.md)
