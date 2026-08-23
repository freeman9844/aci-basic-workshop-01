# 07. 제약, 트러블슈팅, 정리

> 지원 범위, 대표 failure evidence, fresh-session recovery, billing-critical cleanup 기준을 한곳에서 마무리합니다.


## 목표

이 모듈을 완료하면 다음을 할 수 있습니다.

- 지원하지 않는 범위와 해석 제한을 실제 troubleshooting evidence와 연결해 설명할 수 있습니다.
- `results/workshop.env` 기반 recovery 와 missing state file fallback 을 안전하게 구분할 수 있습니다.
- `scripts/cleanup.sh --resource-group "$RG" --yes` 와 residual resource IDs evidence를 사용해 cleanup를 완료할 수 있습니다.
- billing-critical RG deletion 경고를 숨기지 않고 그대로 보존할 수 있습니다.

## 예상 소요 시간

10분

## 시작 전 상태

- Module 06까지 끝나서 `results/summary.json`, `results/summary.csv`, `results/summary.md` 와 raw/diagnostics evidence 가 모두 남아 있다.
- 가능하면 `results/workshop.env` 가 남아 있고, fresh Cloud Shell 에서도 다시 source 할 수 있다.
- `RG` 와 `STANDBY_POOL` 은 살아 있는 쉘 메모리보다 `results/workshop.env` 에 저장된 값이 기준이다.


## 태그 범례

| 태그 | 의미 |
|------|------|
| 🟢 **실행** | 참가자가 직접 입력하거나 수행해야 하는 단계 |
| 👁️ **설명** | 왜 이 단계를 하는지 이해하기 위한 읽기 전용 안내 |
| 📋 **예상 출력** | 실행 결과와 비교할 기준 출력 |
| ⚠️ **주의** | 비용, 순서, 안전성, 계약 조건 안내 |


## 진행 순서

1. hard limitations 와 범위 제외를 먼저 확인합니다.
2. exact RG를 기준으로 cleanup를 실행하고, `az group exists` 와 residual resource IDs evidence를 확인합니다.
3. fresh Cloud Shell recovery 와 missing state file fallback 절차를 마지막까지 정리합니다.

## 0. 세션 재연결 시 상태 복구 (선택)

<details>
<summary>fresh Cloud Shell에서 cleanup 대상 RG를 다시 확인하는 명령 보기</summary>

👁️ **설명**

cleanup 단계는 exact RG 하나를 정확히 다시 잡는 것이 핵심입니다. 새 Cloud Shell에서는 먼저 state file을 source하고, 값이 없다면 이 문서의 fallback 절차로만 복구합니다.

🟢 **실행**

```bash
cd ~/aci-vn2-performance-workshop
source results/workshop.env
printf 'RG=%s\n' "$RG"
```

📋 **예상 출력**

- cleanup 대상 RG 하나만 다시 확인됩니다.
- 값이 비어 있으면 wildcard를 쓰지 말고 3단계 fallback 절차로 exact RG를 먼저 복구합니다.

</details>

👁️ **설명**

아래 단계는 설명 → 실행 → 예상 출력 → 주의 순서로 읽습니다. 코드 블록은 순서를 바꾸지 말고, fail-fast로 멈추면 같은 단계에서 원인을 먼저 정리합니다.

⚠️ **주의**

선행 조건을 확인하지 못했거나 측정 상태가 불분명하면 다음 단계로 넘어가지 않습니다.


### 1) hard limitations 와 범위 제외를 먼저 확인

👁️ **설명**

아래 항목은 이 워크숍에서 지원하지 않거나 의도적으로 제외한 제약입니다.

| 항목 | 의미 |
| --- | --- |
| API server authorized IP ranges | Cloud Shell IP가 바뀌면 접근 제어가 흔들릴 수 있어 이 워크숍 범위에서 다루지 않습니다 |
| Windows | Windows container path 는 실습 범위 밖입니다 |
| IPv6 | IPv6 구성은 실습 범위 밖입니다 |
| DaemonSet | 일반 DaemonSet 경로는 VN2 비교 실습 대상으로 승인되지 않았습니다 |
| Kubernetes network policy | 이 워크숍은 Kubernetes network policy 검증을 포함하지 않습니다 |
| private ACR/private endpoint | public MCR 기준 benchmark 이므로 private registry 네트워크 설계는 범위 제외입니다 |
| multi-region / production recommendation | 한 번의 워크숍 측정으로 운영 capacity recommendation 을 내리지 않습니다 |
| NAP SKU 선택 | `Standard_D4s_v5`를 고정하므로 NAP의 자동 SKU 선택 품질이나 최적화를 비교하지 않습니다 |
| NAP consolidation | consolidation 시간은 run reset에 포함되지만 Pod Ready latency에는 포함되지 않습니다 |
| Image Cache | production 기본값이 아니라 cache 효과를 분리하는 통제된 lab 조건입니다 |
| Azure 변동성 | region, SKU, capacity와 시점에 따라 provisioning 결과와 latency가 달라질 수 있습니다 |

### 2) 안전한 cleanup 명령 실행

🟢 **실행**

반드시 저장소 루트에서 아래 두 줄을 그대로 실행합니다.

```bash
cd ~/aci-vn2-performance-workshop
WORKSHOP_STATE="results/workshop.env"
if [[ -f "$WORKSHOP_STATE" ]]; then
  source "$WORKSHOP_STATE"
fi
if [[ -z "${RG:-}" ]]; then
  printf 'RG is not set. Follow the fresh Cloud Shell recovery steps below before cleanup.\n' >&2
  exit 1
fi
scripts/cleanup.sh --resource-group "$RG" --yes
az group exists --name "$RG"
```

📋 **예상 출력**

정상 종료 뒤 기대하는 마지막 출력은 아래와 같습니다.

```text
false
```

🟢 **실행**

상태를 이미 복구했다면 실제 삭제 명령은 아래 두 줄입니다.

```bash
scripts/cleanup.sh --resource-group "$RG" --yes
az group exists --name "$RG"
```

👁️ **설명**

`cleanup.sh`는 먼저 subscription ID와 resource group 존재 여부를 확인하고, RG가 이미 없으면 조기에 종료합니다. RG가 존재하면 `az standby-container-group-pool list --resource-group "$RG" --query '[].name' --output tsv`로 현재 RG 안의 standby pool 이름만 읽습니다. graceful cluster cleanup은 exact `vn2-bench-` prefix를 가진 per-run namespace만 bounded best-effort sweep으로 삭제하고 `vn2-image-cache` namespace를 삭제한 뒤, 아래 순서로 NAP 리소스 삭제와 NodeClaim 0 관찰을 시도하고 Helm release를 제거합니다. Namespace listing or deletion times out or fails 하면 경고를 보존하고 billing-critical RG deletion을 계속합니다.

🟢 **실행**

```bash
kubectl delete nodepool workshop-nap --ignore-not-found=true --wait=false
kubectl delete aksnodeclass workshop-nap --ignore-not-found=true --wait=false
kubectl get nodeclaims -l karpenter.sh/nodepool=workshop-nap -o name
```

👁️ **설명**

NAP delete는 `--wait=false`로 반환을 기다리지 않으며, NodeClaim 0 관찰을 포함한 각 cluster 명령은 `CLUSTER_CLEANUP_TIMEOUT_SECONDS` 안에서만 실행됩니다. 마지막 명령의 빈 출력이 NodeClaim 0 evidence입니다. NodeClaim이 남아 있거나 timeout이 발생하거나 cluster가 unreachable이면 경고를 남기되, `vn2-standby` / `vn2-ondemand` Helm release, 그 RG 안의 standby pool, 마지막으로 RG 자체 삭제를 계속합니다.

⚠️ **주의**

fresh Cloud Shell session, authorized IP drift, 또는 missing kubeconfig 때문에 `kubectl`/`helm` 이 cluster unreachable warning 을 내더라도 billing-critical RG deletion 은 계속 진행되어야 합니다. 이 경우 `WARNING: graceful cluster cleanup failed; continuing with standby pool and resource group deletion.` 또는 `Cleanup completed with warnings.` 같은 경고는 정상적인 evidence 이며, 숨기지 말고 CLI 출력 그대로 보존하십시오.

👁️ **설명**

`--yes` 를 빼면 script 는 subscription, resource group, Helm releases, standby pools 를 출력한 뒤 `type the resource group name exactly to continue` 를 요구합니다. 즉 cleanup scope 를 이름으로 다시 검증합니다.

cleanup polling 이 실패하거나 RG 가 timeout 안에 사라지지 않으면 script 는 `az resource list --resource-group "$RG" --query '[].id' --output tsv` 를 호출해 residual resource IDs 를 출력합니다. 문서/티켓에는 이 exact residual resource IDs evidence 를 함께 남기십시오.

### 3) fresh Cloud Shell recovery 와 missing state file 대응

👁️ **설명**

fresh Cloud Shell recovery 의 첫 선택지는 항상 기존 state file 입니다.

🟢 **실행**

```bash
cd ~/aci-vn2-performance-workshop
source results/workshop.env
```

👁️ **설명**

만약 `results/workshop.env` 자체가 없다면, 아래 fallback 은 후보 RG를 찾는 용도만 사용합니다.

🟢 **실행**

```bash
cd ~/aci-vn2-performance-workshop
WORKSHOP_STATE="results/workshop.env"
mkdir -p results
az group list --query "[?starts_with(name, 'rg-vn2-bench-')].[name, location]" --output table

export RG="rg-vn2-bench-12345"
STATE_TMP="${WORKSHOP_STATE}.tmp.$$"
(
  umask 077
  printf 'export RG=%q\n' "$RG" >"$STATE_TMP"
)
chmod 600 "$STATE_TMP"
mv "$STATE_TMP" "$WORKSHOP_STATE"
source "$WORKSHOP_STATE"
```

👁️ **설명**

이 표는 broad match 를 보여 줄 뿐이며, 자동 삭제 대상이 아닙니다.

⚠️ **주의**

Never pass a wildcard or broad match into cleanup. 참가자는 Portal, `az group show --name "$RG"`, 또는 기존 evidence 를 대조해 exact RG 하나를 직접 확정해야 합니다. Save the recovered exact RG back into results/workshop.env before deleting anything.

👁️ **설명**

`STANDBY_POOL` 이 꼭 필요하면 exact RG 를 확인한 다음 그 RG 안에서 다시 조회하십시오. 그러나 cleanup 자체는 broad match 를 받아서는 안 되며, `rg-vn2-bench-*` 같은 패턴을 `scripts/cleanup.sh` 에 직접 넘기면 안 됩니다.

## 문제 해결

| 증상 | 실제 증거 | 확인 명령 | 조치 |
| --- | --- | --- | --- |
| NAP node가 생성되지 않거나 reset되지 않는다 | checker JSON에서 NodePool Ready일 때 `health=ready`입니다. NodePool 조회 실패는 health가 `missing`, Ready condition 실패는 health가 `degraded`, deadline 초과는 health가 `timeout`입니다. timeout 합성 evidence에서는 아직 관찰하지 못한 `nodes`와 `nodeclaims`가 `null`이므로 0으로 간주하면 안 됩니다 | `kubectl get nodepool workshop-nap -o yaml`, `kubectl get nodeclaims -l karpenter.sh/nodepool=workshop-nap -o yaml`, `kubectl get events -A --field-selector source=karpenter-events` | NodePool condition, NodeClaim provisioning/consolidation event, quota와 `Standard_D4s_v5` capacity를 확인합니다. run 전후 NodeClaim 0이 확인되지 않으면 다음 run을 시작하지 않습니다 |
| VN2 node 가 `NotReady` 이다 | virtual node 자체보다 먼저 infrastructure Pod/cluster event 를 봐야 한다 | `kubectl get nodes -L benchmark-path -o wide`, `kubectl get pods -A -o wide`, `kubectl get events -A --sort-by=.metadata.creationTimestamp \| tail -n 40` | 두 VN2 infrastructure release와 benchmark Pod 5개 × 500m baseline 을 함께 수용하는 `Standard_D16s_v5` 기준 capacity, kubelet/Standby Pool RBAC, subnet 설정을 확인한 뒤 `NotReady` 원인을 먼저 제거한다 |
| standby pool 이 degraded 로 보인다 | Azure CLI 원본은 `status.code` 에 `HealthState/Degraded` 같은 값을 주고, checker 출력은 `{"health":"degraded"}` 로 정규화한다 | `./scripts/check-standby-pool.sh -g "$RG" -n "$STANDBY_POOL" --expect-running 5 --timeout-seconds 1200 --interval-seconds 15`, `az standby-container-group-pool status --resource-group "$RG" --name "$STANDBY_POOL" --version latest --output json` | degraded 를 숨기지 말고 RBAC, delegated subnet, quota, region 상태를 먼저 확인한다 |
| running count 가 5 아래로 떨어진다 | healthy 여도 `running` 이 4 이하이면 warm capacity 가 아직 덜 찬 것이다 | `./scripts/check-standby-pool.sh -g "$RG" -n "$STANDBY_POOL" --expect-running 5 --timeout-seconds 1200 --interval-seconds 15`, `az standby-container-group-pool status --resource-group "$RG" --name "$STANDBY_POOL" --version latest --output json` | running 5 가 될 때까지 기다리거나 quota/capacity 이슈를 해결한 뒤 다음 run 으로 간다 |
| cached scenario 가 uncached 보다 빠르지 않다 | summary 와 diagnostics 를 같이 읽어야 한다. cache Pod 또는 recycle 이 빠지면 해석이 틀어진다 | `jq '.["vn2-standby-cached"] | {scenario, runs_count, ready_samples, failed_count, timeout_count, create_to_ready_ms, batch_all_ready_ms, pod_speedup_ratio, batch_speedup_ratio}' results/summary.json`, `kubectl get pod -n vn2-image-cache vn2-benchmark-image-cache -o yaml`, `sed -n '1,160p' results/diagnostics/vn2-standby-cached-run-1/kubectl-events.txt`, `cat results/diagnostics/vn2-standby-cached-run-1/az-container-list.json` | cache Pod 존재, `--max-ready-capacity 0`, `--max-ready-capacity 5` recycle, running 5 복구를 모두 확인한 뒤에만 cached 효과를 해석한다 |
| standby fallback 흔적이 보인다 | raw metadata 또는 summary evidence 에 `StandbyPoolReuseFailure`, `StandbyPoolExhaustedPool` 가 남아 있으면 warm reuse 대신 fallback 이 섞였을 수 있다 | `grep -R --line-number -E 'StandbyPoolReuseFailure|StandbyPoolExhaustedPool' results/summary.json results/summary.csv results/summary.md results/raw results/diagnostics || true` | 해당 run 을 fallback-contaminated 로 표시하고 clean standby comparison 에서 별도로 설명한다 |
| Pod 가 timeout 이거나 image pull/NAT/quota 의심이 든다 | raw JSON 의 `terminal_failure_reason`, `terminal_failure_message`, `container_state` 와 diagnostics 를 같이 봐야 한다 | `jq '.pods[] | select(.terminal_state != "ready") | {name, terminal_state, terminal_failure_reason, terminal_failure_message, create_to_scheduled_ms, scheduled_to_ready_ms, create_to_ready_ms, container_state}' results/raw/vn2-standby-cached-run-1.json`, `sed -n '1,160p' results/diagnostics/vn2-standby-cached-run-1/kubectl-events.txt`, `cat results/diagnostics/vn2-standby-cached-run-1/az-container-list.json` | `ImagePullBackOff`, `ErrImagePull`, quota 부족, NAT Gateway outbound 누락, image pull 지연을 구분하고 수정 후 실패 시나리오만 다시 실행한다 |

### cleanup 실패 시 재확인 순서

1. `az group exists --name "$RG"` 가 아직 `true` 면 cleanup 이 끝나지 않은 것입니다.
2. `az resource list --resource-group "$RG" --query '[].id' --output tsv` 로 exact residual resource IDs 를 확인합니다.
3. fresh Cloud Shell session 이거나 kubeconfig 가 비어 있어도 `scripts/cleanup.sh --resource-group "$RG" --yes` 는 billing-critical RG deletion 을 다시 시도해야 합니다. cluster cleanup warning 이 보이면 expected evidence 로 간주하고 같은 RG 로 다시 실행합니다.
4. 그래도 실패하면 resource ID 와 CLI 오류를 그대로 보존하고, 어떤 단계에서 멈췄는지 공유합니다.

## 완료 체크포인트

- API server authorized IP ranges, Windows, IPv6, DaemonSet, Kubernetes network policy 등 hard limitations 를 팀에 설명할 수 있다.
- troubleshooting 표의 각 행에 대해 실제 evidence 파일 또는 CLI 명령을 다시 실행할 수 있다.
- NAP checker의 ready/missing/degraded/timeout 상태와 unknown `null` count를 구분하고 NodeClaim 0을 확인할 수 있다.
- `results/workshop.env` 를 source 하는 정상 경로와 missing state file 때의 fresh Cloud Shell recovery 경로를 모두 설명할 수 있다.
- `scripts/cleanup.sh --resource-group "$RG" --yes` 를 실행했다.
- `az group exists --name "$RG"` 결과가 최종적으로 `false` 다.
- cleanup scope 검증과 residual resource IDs 동작을 설명할 수 있다.

## 이전/다음

- 이전: [Module 06](./06-analyze-results.md)
- 다음: [README](../README.md)
