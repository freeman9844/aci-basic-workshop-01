# 05. StandbyPool hands-on 관찰

> Pod 1개를 한 번 warm StandbyPool 경로로 실행하고, `pre.running=1`과 `post.running=1`을 통해 ready capacity 소비와 refill을 `results/observations/`와 `results/evidence/`에서 확인합니다.


## 목표

이 모듈을 완료하면 다음을 할 수 있습니다.

- `results/workshop.env`에서 같은 `$RG`, `$AKS`, `$STANDBY_POOL` 상태를 복구할 수 있습니다.
- `./scripts/check-standby-pool.sh`로 실행 전 running 1을 확인할 수 있습니다.
- `./scripts/run-hands-on.sh`로 `vn2-standby`를 Pod 1개, 한 번 실행할 수 있습니다.
- `results/observations/vn2-standby.json`와 `results/evidence/`에서 standby pre/post 증적을 읽을 수 있습니다.
- `pre.running=1`과 `post.running=1`이 workload가 아직 running인 동안 ready-capacity 소비와 refill을 보여 준다고 설명할 수 있습니다.
- 이 모듈도 benchmark 또는 SLA가 아닙니다 라는 caveat를 유지할 수 있습니다.

## 예상 소요 시간

15분

## 시작 전 상태

- Module 04까지 끝나 `results/observations/vn2-ondemand.json`과 관련 `results/evidence/`가 남아 있다.
- `results/workshop.env`에 `RG`, `AKS`, `STANDBY_POOL` 값이 저장되어 있다.
- standby virtual node가 Ready이고 standby pool을 running 1로 채울 수 있다.
- 같은 Cloud Shell을 계속 쓰거나, fresh Cloud Shell이면 kubeconfig를 다시 불러올 수 있다.


## 태그 범례

| 태그 | 의미 |
|------|------|
| 🟢 **실행** | 참가자가 직접 입력하거나 수행해야 하는 단계 |
| 👁️ **설명** | 왜 이 단계를 하는지 이해하기 위한 읽기 전용 안내 |
| 📋 **예상 출력** | 실행 결과와 비교할 기준 출력 |
| ⚠️ **주의** | 비용, 순서, 안전성, 해석 제한 안내 |


## 진행 순서

1. `results/workshop.env`와 kubeconfig를 복구합니다.
2. standby pool이 running 1인지 먼저 확인합니다.
3. `vn2-standby`를 한 번 실행합니다.
4. `results/observations/`와 `results/evidence/`에서 pre/post refill 증적을 읽습니다.

## 0. 세션 재연결 시 상태 복구 (선택)

<details>
<summary>fresh Cloud Shell에서 standby state와 kubeconfig를 다시 맞추는 명령 보기</summary>

👁️ **설명**

새 Cloud Shell에서는 standby pool 이름과 AKS context를 먼저 복구해야 합니다. 같은 shell을 계속 쓰고 있다면 이 절은 건너뜁니다.

🟢 **실행**

```bash
cd ~/aci-vn2-performance-workshop
source results/workshop.env
az aks get-credentials --resource-group "$RG" --name "$AKS" --overwrite-existing
printf 'RG=%s\nSTANDBY_POOL=%s\n' "$RG" "$STANDBY_POOL"
```

📋 **예상 출력**

- 현재 workshop resource group과 standby pool 이름이 다시 보입니다.
- kubeconfig가 현재 AKS를 가리키면 아래 단계로 이어갈 수 있습니다.

</details>

👁️ **설명**

아래 단계는 설명 → 실행 → 예상 출력 → 주의 순서로 읽습니다. 코드 블록은 순서를 바꾸지 말고, fail-fast로 멈추면 같은 단계에서 원인을 먼저 정리합니다.

⚠️ **주의**

standby hands-on은 같은 `$STANDBY_POOL`을 계속 써야 해석이 맞습니다. pool 이름을 추측하지 말고 `results/workshop.env` 기준으로만 진행합니다.


### 1) workshop state와 kubeconfig 복구

🟢 **실행**

```bash
cd ~/aci-vn2-performance-workshop
source results/workshop.env
az aks get-credentials --resource-group "$RG" --name "$AKS" --overwrite-existing
```

👁️ **설명**

`./scripts/run-hands-on.sh`는 standby 관찰을 위해 `kubectl`과 `az`를 모두 사용합니다. 따라서 state file과 kubeconfig를 먼저 같은 AKS로 맞춰 두는 것이 안전합니다.

### 2) standby pool running 1 precheck

👁️ **설명**

active 실습의 standby baseline은 ready capacity 1입니다. 먼저 pool이 healthy하고 running 1인지 확인한 뒤 Pod 1개를 한 번 실행합니다.

🟢 **실행**

```bash
./scripts/check-standby-pool.sh \
  --resource-group "$RG" \
  --name "$STANDBY_POOL" \
  --expect-running 1 \
  --timeout-seconds 1200 \
  --interval-seconds 15
```

📋 **예상 출력**

성공하면 아래와 비슷한 JSON 한 줄이 출력됩니다.

```text
{"creating":0,"deleting":0,"health":"healthy","provisioning_state":"Succeeded","running":1,"starting":0}
```

⚠️ **주의**

running 1이 확인되지 않으면 다음 단계로 넘어가지 않습니다. 먼저 same pool을 healthy 상태로 복구한 뒤 다시 확인합니다.

### 3) Pod 1개 StandbyPool observation 실행

👁️ **설명**

이 명령은 같은 standby path에서 Pod 1개를 한 번 실행합니다. observation JSON에는 standby pre/post check 결과가 함께 저장됩니다.

🟢 **실행**

```bash
./scripts/run-hands-on.sh \
  --scenario vn2-standby \
  --resource-group "$RG" \
  --standby-pool "$STANDBY_POOL" \
  --output-dir results
```

📋 **예상 출력**

성공 예시는 다음과 비슷합니다.

```text
vn2-standby phase=Pending node=virtual-node-standby ready=false elapsed=28ms
vn2-standby phase=Running node=virtual-node-standby ready=true elapsed=4321ms
vn2-standby Pod became Ready in 4.3 seconds.
This is one workshop observation, not a benchmark or SLA.
```

### 4) observation JSON과 refill 증적 확인

👁️ **설명**

active 관찰 결과는 `results/observations/`에 scenario별 JSON으로, 세부 파일은 `results/evidence/` 아래 attempt별 디렉터리로 남습니다.

🟢 **실행**

```bash
jq '{scenario, status, elapsed_ms, standby_pool, cleanup}' \
  results/observations/vn2-standby.json
find results/evidence -maxdepth 1 -type d -name 'vn2-standby-*' | sort | tail -n 1
```

📋 **예상 출력**

- `standby_pool.pre.running`과 `standby_pool.post.running`을 같은 JSON에서 볼 수 있습니다.
- 두 번째 명령은 최신 standby evidence 디렉터리 하나를 출력합니다.

👁️ **설명**

`pre.running=1`은 실행 직전 ready capacity가 하나 있었다는 뜻입니다. `post.running=1`은 workload가 아직 running인 동안에도 same pool이 ready-capacity를 다시 채웠다는 뜻이므로, ready-capacity 소비와 refill이 observation에 포함되었다고 설명할 수 있습니다.

최신 `results/evidence/vn2-standby-.../` 안에는 `standby-pre.json`, `standby-post.json`, `pod.json`, `pod-live.yaml`, `events.txt`, `nodes.json`, `aci-inventory.json` 같은 증적이 남습니다.

⚠️ **주의**

이 값은 standby path의 한 번의 hands-on 관찰입니다. benchmark 또는 SLA가 아닙니다.

## 완료 체크포인트

- `source results/workshop.env` 와 kubeconfig 복구를 마쳤다.
- `./scripts/check-standby-pool.sh --resource-group "$RG" --name "$STANDBY_POOL" --expect-running 1 --timeout-seconds 1200 --interval-seconds 15` 를 실행했다.
- `./scripts/run-hands-on.sh --scenario vn2-standby --resource-group "$RG" --standby-pool "$STANDBY_POOL" --output-dir results` 를 실행했다.
- `results/observations/vn2-standby.json`에서 `pre.running=1`과 `post.running=1`을 확인했다.
- 최신 `results/evidence/` 디렉터리에서 standby pre/post JSON을 열 수 있다.
- 이 observation이 benchmark 또는 SLA가 아님을 다시 말할 수 있다.

## 문제 해결

| 증상 | 확인 명령 | 조치 |
| --- | --- | --- |
| `STANDBY_POOL` 값이 비어 있다 | `sed -n '1,80p' results/workshop.env` | Module 03 state 복구 절차로 정확한 pool 이름을 다시 저장한 뒤 재시도합니다 |
| precheck가 running 1을 만족하지 못한다 | `./scripts/check-standby-pool.sh --resource-group "$RG" --name "$STANDBY_POOL" --expect-running 1 --timeout-seconds 1200 --interval-seconds 15` | JSON 출력의 `health`, `running`, `starting` 값을 보고 먼저 same pool을 healthy/running 1로 되돌립니다 |
| observation은 성공했지만 refill 근거를 설명하기 어렵다 | `jq '.standby_pool' results/observations/vn2-standby.json` | `pre.running=1`과 `post.running=1`을 직접 읽고, workload가 아직 running인 동안 refill이 일어났다고 설명합니다 |
| namespace cleanup이 실패했다 | `jq '.cleanup' results/observations/vn2-standby.json` | `cleanup.reason`을 기록하고 Module 07 cleanup 전에 잔여 namespace를 다시 확인합니다 |

## 이전/다음

- 이전: [Module 04](./04-vn2-ondemand-hands-on.md)
- 다음: [Module 06](./06-image-cache-hands-on.md)
