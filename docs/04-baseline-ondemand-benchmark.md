# 04. AKS NAP와 VN2 OnDemand 측정 실행

> 같은 benchmark template로 `aks-nap`과 `vn2-ondemand`를 5 Pods × 3회 실행하고, 0→1→0 NAP evidence와 raw diagnostics를 함께 수집합니다.


## 목표

이 모듈을 완료하면 다음을 할 수 있습니다.

- `results/workshop.env` 와 helper를 같은 shell에서 복구해 benchmark를 다시 시작할 수 있습니다.
- `workshop-nap` NodePool의 node/NodeClaim 0-state를 확인한 뒤 `aks-nap`을 안전하게 3회 실행할 수 있습니다.
- `aks-nap` run마다 NAP node/NodeClaim 0 → 1 → 0 evidence를 raw JSON과 diagnostics로 확인할 수 있습니다.
- `aks-nap` 과 `vn2-ondemand` 의 run별 JSON, diagnostics, archive/retry 흐름을 분리해 관리할 수 있습니다.
- `vn2-ondemand` 3회 실행에서 raw JSON, diagnostics, ACI inventory evidence를 보존할 수 있습니다.
- 실패한 scenario만 archive하고 같은 scenario만 재실행할 수 있습니다.

## 예상 소요 시간

45분

## 시작 전 상태

- Module 02의 `workshop-nap` NodePool이 Ready이고 NAP node와 NodeClaim이 모두 0개다.
- Module 03의 `benchmark-path=ondemand`와 `benchmark-path=standby` virtual node가 Ready다.
- `results/workshop.env`를 fresh Cloud Shell에서도 다시 source할 수 있다.
- 이전 실패 evidence를 삭제하지 않고 `results/failed-attempts/`로 옮긴 뒤 재시도할 준비가 되었다.


## 태그 범례

| 태그 | 의미 |
|------|------|
| 🟢 **실행** | 참가자가 직접 입력하거나 수행해야 하는 단계 |
| 👁️ **설명** | 왜 이 단계를 하는지 이해하기 위한 읽기 전용 안내 |
| 📋 **예상 출력** | 실행 결과와 비교할 기준 출력 |
| ⚠️ **주의** | 비용, 순서, 안전성, 계약 조건 안내 |


## 진행 순서

1. workshop state와 interactive-safe helper를 복구합니다.
2. `workshop-nap`의 node/NodeClaim이 0인지 명시적으로 확인합니다.
3. `aks-nap`을 3회 실행하고 run별 0 → 1 → 0 evidence를 확인합니다.
4. `vn2-ondemand`를 3회 실행하고 raw JSON과 diagnostics를 확인합니다.
5. 실패한 시나리오만 archive한 뒤 복구하고 다시 실행합니다.


## 0. 세션 재연결 시 상태 복구 (선택)

<details>
<summary>fresh Cloud Shell에서 benchmark state 복구 명령 보기</summary>

👁️ **설명**

새 Cloud Shell에서는 `results/workshop.env` 를 먼저 불러와 `$RG` 와 `$STANDBY_POOL` 을 다시 확인합니다. 이 값이 맞지 않으면 benchmark evidence 경로도 달라집니다.

🟢 **실행**

```bash
cd ~/aci-vn2-performance-workshop
source results/workshop.env
printf 'RG=%s\nSTANDBY_POOL=%s\n' "$RG" "$STANDBY_POOL"
```

📋 **예상 출력**

- 현재 workshop resource group과 standby pool 이름이 한 번에 다시 보입니다.
- 값이 비어 있으면 Module 02 또는 Module 03의 recovery 절차부터 다시 실행합니다.

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

check_nap_state() {
  local label="$1"

  run_and_capture_rc "$label" \
    ./scripts/check-nap-capacity.sh \
      --name workshop-nap \
      --expect-nodes 0 \
      --expect-nodeclaims 0 \
      --timeout-seconds 1200 \
      --interval-seconds 15
  NAP_CHECK_RC=$?

  case "$NAP_CHECK_RC" in
    0)
      printf '%s succeeded.\n' "$label"
      ;;
    2)
      printf 'RC=2 means the NAP NodePool is missing, unreadable, or not Ready.\n' >&2
      printf 'Keep the JSON output as evidence, recover Module 02, and rerun the same check.\n' >&2
      ;;
    3)
      printf 'RC=3 means NAP nodes or NodeClaims did not reach zero before timeout.\n' >&2
      printf 'Do not start another run; inspect remaining workloads and Karpenter state first.\n' >&2
      ;;
    *)
      printf '%s returned unexpected RC=%s\n' "$label" "$NAP_CHECK_RC" >&2
      ;;
  esac

  return "$NAP_CHECK_RC"
}

mkdir -p results
require_workshop_vars
```

👁️ **설명**

persistent errexit 설정은 사용하지 않습니다. checker나 benchmark의 nonzero exit code를 기록하고 같은 shell에서 evidence 확인과 복구를 계속해야 합니다.

### 2) NAP NodePool과 zero-capacity precheck

🟢 **실행**

```bash
check_nap_state "NAP zero-capacity precheck"
```

🟢 **실행**

helper를 복구하지 않은 shell에서는 다음 표준 명령을 직접 실행합니다.

```bash
./scripts/check-nap-capacity.sh \
  --name workshop-nap \
  --expect-nodes 0 \
  --expect-nodeclaims 0 \
  --timeout-seconds 1200 \
  --interval-seconds 15
```

⚠️ **주의**

exit code가 0일 때만 benchmark를 시작합니다. RC=2이면 NodePool 상태를 복구하고, RC=3이면 남은 node/NodeClaim과 workload를 조사합니다. zero state가 확인되지 않은 상태에서 다음 run을 시작하지 않습니다.

### 3) `aks-nap` 3회 실행

🟢 **실행**

```bash
run_and_capture_rc "aks-nap benchmark" \
  ./scripts/run-benchmark.sh \
    --scenario aks-nap \
    --runs 3 \
    --output-dir results
NAP_RC=$?

case "$NAP_RC" in
  0)
    printf 'aks-nap benchmark completed all 3 runs.\n'
    ;;
  2)
    printf 'RC=2 means a benchmark sample timed out or failed after raw JSON and diagnostics were written.\n' >&2
    printf 'RC=2 can also mean the internal NAP pre-run or post-run check reported a missing or degraded NodePool, so the current run may not have new raw JSON.\n' >&2
    printf 'The runner stops remaining runs after the first failed sample.\n' >&2
    printf 'Inspect existing evidence and run check_nap_state "NAP zero-capacity recovery check" before retrying only aks-nap.\n' >&2
    ;;
  3)
    printf 'RC=3 means the internal NAP pre-run or post-run zero-capacity check timed out.\n' >&2
    printf 'Do not continue; preserve the JSON check result and recover node/NodeClaim zero state first.\n' >&2
    ;;
  124)
    printf 'RC=124 means the overall scenario deadline expired.\n' >&2
    printf 'Preserve all completed raw and diagnostics paths, recover zero state, then retry only aks-nap.\n' >&2
    ;;
  *)
    printf 'Unexpected aks-nap benchmark failure RC=%s\n' "$NAP_RC" >&2
    ;;
esac
```

👁️ **설명**

runner는 세 run 각각에서 Pod 생성 전에 `nap-precheck.json`으로 0/0을 확인합니다. Pod가 Ready인 동안 `nap-nodeclaims.yaml`, `kubectl-nodes.json`, `nap-nodepool.yaml`, `nap-events.txt`를 수집하고, namespace 삭제 뒤 `nap-postcheck.json`으로 다시 0/0을 확인합니다. post-check가 실패하면 다음 run을 시작하지 않습니다.

### 4) run별 NAP 0 → 1 → 0 evidence 확인

🟢 **실행**

```bash
find results/raw -maxdepth 1 -type f -name 'aks-nap-run-*.json' | sort
jq -r '.pods[] | [.name, .terminal_state, .create_to_ready_ms, .node_name] | @tsv' results/raw/aks-nap-run-1.json
jq '{scenario, run, batch: {first_ready_ms: .batch.first_ready_ms, all_ready_ms: .batch.all_ready_ms}}' results/raw/aks-nap-run-1.json

for run in 1 2 3; do
  evidence="results/diagnostics/aks-nap-run-${run}"
  jq '{nodes, nodeclaims, ready}' "$evidence/nap-precheck.json"
  sed -n '1,200p' "$evidence/nap-nodeclaims.yaml"
  sed -n '1,200p' "$evidence/kubectl-nodes.json"
  jq '{nodes, nodeclaims, ready}' "$evidence/nap-postcheck.json"
done

find results/diagnostics -maxdepth 2 -type f -path '*/aks-nap-run-*/*' | sort
```

📋 **예상 출력**

성공한 각 run에서 다음 연결을 확인합니다.

- 시작 0: `nap-precheck.json`의 `nodes: 0`, `nodeclaims: 0`, `ready: true`
- scale-out 1: `nap-nodeclaims.yaml`과 `kubectl-nodes.json`에 `workshop-nap` NodeClaim/node가 하나 있으며 raw Pod의 `node_name`이 그 node를 가리킴
- 종료 0: `nap-postcheck.json`의 `nodes: 0`, `nodeclaims: 0`, `ready: true`

예상 Pod 이름은 `aks-nap-run-1-pod-1`, `aks-nap-run-1-pod-2`처럼 새 scenario ID를 포함합니다. `results/diagnostics/aks-nap-run-1/`에는 위 NAP 파일 외에도 `kubectl-describe-pods.txt`, `kubectl-events.txt`, `kubectl-nodes.json`, `az-container-list.json`이 남습니다. `az-container-list.json`의 `skipped --resource-group not provided`는 AKS NAP run에서 정상입니다.

### 5) `VN2 OnDemand` 3회 실행

🟢 **실행**

```bash
run_and_capture_rc "vn2-ondemand benchmark" \
  ./scripts/run-benchmark.sh \
    --scenario vn2-ondemand \
    --runs 3 \
    --resource-group "$RG" \
    --output-dir results
ONDEMAND_RC=$?

case "$ONDEMAND_RC" in
  0)
    printf 'vn2-ondemand benchmark completed all 3 runs.\n'
    ;;
  2)
    printf 'RC=2 means a benchmark sample timed out or failed after raw JSON and diagnostics were written.\n' >&2
    printf 'The runner stops remaining runs after the first failed sample.\n' >&2
    printf 'Inspect existing evidence, archive fixed paths, and retry only vn2-ondemand.\n' >&2
    ;;
  124)
    printf 'RC=124 means the overall scenario deadline expired.\n' >&2
    printf 'Preserve completed evidence before retrying only vn2-ondemand.\n' >&2
    ;;
  *)
    printf 'Unexpected vn2-ondemand benchmark failure RC=%s\n' "$ONDEMAND_RC" >&2
    ;;
esac
```

👁️ **설명**

이 경로는 standby ready capacity 없이 ACI container group을 net-new로 준비합니다. 모든 VN2 scenario는 per-run ACI inventory를 남기기 위해 `--resource-group "$RG"`가 필수이며, 누락하면 runner가 benchmark 시작 전에 RC=64로 종료합니다. 따라서 VN2 run의 `az-container-list.json`이 resource group 누락 때문에 skip placeholder가 되는 것을 허용하지 않습니다.

🟢 **실행**

```bash
find results/raw -maxdepth 1 -type f -name 'vn2-ondemand-run-*.json' | sort
jq -r '.pods[] | [.name, .terminal_state, .create_to_ready_ms, .node_name] | @tsv' results/raw/vn2-ondemand-run-1.json
jq '{scenario, run, batch: {first_ready_ms: .batch.first_ready_ms, all_ready_ms: .batch.all_ready_ms}}' results/raw/vn2-ondemand-run-1.json
find results/diagnostics -maxdepth 2 -type f -path '*/vn2-ondemand-run-*/*' | sort
```

👁️ **설명**

`results/diagnostics/vn2-ondemand-run-1/`의 `kubectl-describe-pods.txt`, `kubectl-events.txt`, `kubectl-nodes.json`, `az-container-list.json`도 삭제하지 않습니다.

### 6) 실패한 시나리오만 archive하고 재실행

👁️ **설명**

같은 scenario를 재실행하면 고정 raw/diagnostics 경로가 덮어써집니다. Run the archive/rerun example only for the scenario that failed. Do not archive or rerun a scenario that already succeeded.

🟢 **실행**

```bash
# Example: rerun only the failed scenario after reviewing evidence.
# Uncomment one block, not both.

# If aks-nap failed:
# check_nap_state "NAP zero-capacity recovery check"
# archive_failed_attempts aks-nap
# ./scripts/run-benchmark.sh \
#   --scenario aks-nap \
#   --runs 3 \
#   --output-dir results

# If vn2-ondemand failed:
# archive_failed_attempts vn2-ondemand
# ./scripts/run-benchmark.sh \
#   --scenario vn2-ondemand \
#   --runs 3 \
#   --resource-group "$RG" \
#   --output-dir results
```

## 완료 체크포인트

- 시작 전 `workshop-nap` NodePool Ready와 node/NodeClaim 0/0을 확인했다.
- `aks-nap`와 `vn2-ondemand` 명령을 각각 `--runs 3`으로 실행하고 exit code를 기록했다.
- 두 시나리오 명령이 모두 0으로 끝났을 때만 정확히 6개의 raw 파일을 기대합니다.
- `results/raw/aks-nap-run-{1,2,3}.json`과 `results/raw/vn2-ondemand-run-{1,2,3}.json`을 확인했다.
- 각 NAP run에서 precheck 0, active NodeClaim/node 1, postcheck 0 evidence를 확인했다.
- 실패/timeout evidence를 보존하고 실패한 scenario만 archive/retry한다.

## 문제 해결

| 증상 | 확인 | 조치 |
| --- | --- | --- |
| NAP precheck가 RC=2다 | `kubectl get nodepool workshop-nap -o yaml`, `cat results/diagnostics/aks-nap-run-1/nap-precheck.json` | NodePool Ready와 AKS context를 복구한 뒤 같은 zero-state check를 다시 실행 |
| NAP pre/post check가 RC=3 또는 scenario가 RC=124다 | `kubectl get nodes -l karpenter.sh/nodepool=workshop-nap`, `kubectl get nodeclaims -l karpenter.sh/nodepool=workshop-nap`, `cat results/diagnostics/aks-nap-run-1/nap-postcheck.json` | workload와 namespace 정리를 확인하고 0/0이 될 때까지 기다린다. zero state 전에는 다음 run을 시작하지 않음 |
| benchmark가 RC=2다 | `jq '{scenario, run, batch, pods: [.pods[] | {name, terminal_state, create_to_ready_ms, node_name}]}' results/raw/aks-nap-run-1.json`, `sed -n '1,160p' results/diagnostics/aks-nap-run-1/kubectl-events.txt` | raw/diagnostics를 보존하고 실패한 scenario만 archive한 뒤 재실행 |
| raw 파일이 6개보다 적다 | `find results/raw -maxdepth 1 -type f -name 'aks-nap-run-*.json' \| sort`, `find results/raw -maxdepth 1 -type f -name 'vn2-ondemand-run-*.json' \| sort` | 첫 failure 뒤 남은 run이 중단된 정상 fail-fast 결과일 수 있다. evidence 확인 후 해당 scenario만 복구 |

## 이전/다음

- 이전: [Module 03](./03-install-dual-vn2.md)
- 다음: [Module 05](./05-standby-cache-benchmark.md)
