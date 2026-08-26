# 07. 회고와 cleanup

> 세 가지 observation JSON을 질적으로 review하고, exact RG만 사용해 billing-safe cleanup까지 마무리합니다.


## 목표

이 모듈을 완료하면 다음을 할 수 있습니다.

- `results/observations/vn2-ondemand.json`, `results/observations/vn2-standby.json`, `results/observations/vn2-standby-cached.json`을 같은 형식으로 읽을 수 있습니다.
- 세 경로를 `경로`, `관찰 시간`, `lifecycle에서 확인한 점`, `증적 경로` 네 칸으로 정리할 수 있습니다.
- `results/workshop.env`와 fresh Cloud Shell recovery fallback을 구분해 exact RG를 다시 잡을 수 있습니다.
- `scripts/cleanup.sh --resource-group "$RG" --yes`와 `az group exists --name "$RG"`로 전체 삭제를 검증할 수 있습니다.
- VN2, standby health, ImagePull, quota, NAT Gateway 관련 증적을 Module 04-06의 evidence에서 다시 찾을 수 있습니다.

## 예상 소요 시간

10분

## 시작 전 상태

- Module 06까지 끝나 `results/observations/` 아래 세 개의 observation JSON이 남아 있다.
- `results/evidence/` 아래에 `vn2-ondemand-*`, `vn2-standby-*`, `vn2-standby-cached-*` 증적 디렉터리가 남아 있다.
- 가능하면 `results/workshop.env`가 남아 있고, same shell 또는 fresh Cloud Shell session에서 다시 source 할 수 있다.
- cleanup 전에 exact RG를 기억으로 추측하지 않고 파일과 증적으로 다시 확인할 준비가 되어 있다.


## 태그 범례

| 태그 | 의미 |
|------|------|
| 🟢 **실행** | 참가자가 직접 입력하거나 수행해야 하는 단계 |
| 👁️ **설명** | 왜 이 단계를 하는지 이해하기 위한 읽기 전용 안내 |
| 📋 **예상 출력** | 실행 결과와 비교할 기준 출력 |
| ⚠️ **주의** | 비용, 순서, 안전성, 해석 제한 안내 |


## 진행 순서

1. 세 개의 observation JSON을 같은 형식으로 읽습니다.
2. 세 줄 worksheet에 관찰 결과와 evidence 경로를 옮깁니다.
3. 값의 해석 경계와 트러블슈팅 포인트를 정리합니다.
4. exact RG cleanup를 실행하고 `false`를 확인합니다.
5. fresh Cloud Shell recovery와 missing state file fallback을 정리합니다.

## 0. 세션 재연결 시 상태 복구 (선택)

<details>
<summary>fresh Cloud Shell recovery로 exact RG를 다시 불러오는 명령 보기</summary>

👁️ **설명**

같은 shell을 계속 쓰고 있다면 이 절은 건너뜁니다. fresh Cloud Shell session에서는 먼저 기존 state file을 source 하고, 값이 비어 있거나 파일이 없을 때만 이 문서의 fallback 절차를 사용합니다.

🟢 **실행**

```bash
cd ~/aci-vn2-performance-workshop
source results/workshop.env
printf 'RG=%s\n' "$RG"
```

📋 **예상 출력**

- cleanup 대상 exact RG 하나만 다시 보입니다.
- 값이 비어 있으면 wildcard를 쓰지 말고 5단계 fallback으로 이동합니다.

</details>

👁️ **설명**

아래 단계는 설명 → 실행 → 예상 출력 → 주의 순서로 읽습니다. 코드 블록은 순서를 바꾸지 말고, fail-fast로 멈추면 같은 단계에서 원인을 먼저 정리합니다.

⚠️ **주의**

선행 상태를 확인하지 못했거나 observation 해석이 흔들리면 cleanup 전에 증적부터 다시 확인합니다.


### 1) observation JSON 세 개를 먼저 review

👁️ **설명**

Module 04-06의 active 산출물은 각각 `results/observations/vn2-ondemand.json`, `results/observations/vn2-standby.json`, `results/observations/vn2-standby-cached.json` 입니다. aggregate를 만들지 말고, 세 파일을 같은 형식으로 나란히 읽습니다.

🟢 **실행**

```bash
for scenario in vn2-ondemand vn2-standby vn2-standby-cached; do
  jq -r '[.scenario, .status, (.elapsed_ms | tostring), .node_name, .cleanup.status] | @tsv' \
    "results/observations/${scenario}.json"
done
```

📋 **예상 출력**

- scenario 하나당 TSV 한 줄씩 총 세 줄이 나옵니다.
- 각 줄에는 `scenario`, `status`, `elapsed_ms`, `node_name`, `cleanup.status`가 같은 순서로 보입니다.
- 실패가 있었다면 `status` 또는 `cleanup.status`가 그대로 드러나야 하며, 숨기거나 평균으로 덮지 않습니다.

👁️ **설명**

이 출력은 발표용 순위표가 아니라 review 시작점입니다. 경로별로 어떤 lifecycle을 보았는지, cleanup가 바로 끝났는지, 추가 증적을 어디서 열어야 하는지만 확인합니다.

### 2) 세 줄 worksheet에 관찰을 옮기기

👁️ **설명**

각 관찰은 숫자 하나보다 증적 묶음과 함께 읽어야 합니다. 먼저 evidence 디렉터리를 찾아 두고, 표의 빈칸을 팀 메모로 채웁니다.

🟢 **실행**

```bash
find results/evidence -maxdepth 1 -type d \
  \( -name 'vn2-ondemand-*' -o -name 'vn2-standby-*' -o -name 'vn2-standby-cached-*' \) \
  | sort
```

📋 **예상 출력**

- OnDemand, StandbyPool, Image Cache 각각에 대응하는 evidence 디렉터리 경로가 보입니다.
- 표의 `증적 경로` 칸에는 가장 최근 디렉터리 하나씩만 적어 두면 충분합니다.

| 경로 | 관찰 시간 | lifecycle에서 확인한 점 | 증적 경로 |
| --- | --- | --- | --- |
| VN2 OnDemand | `results/observations/vn2-ondemand.json`의 `elapsed_ms` | `phase=Pending → phase=Running` 동안 net-new ACI sandbox 준비가 보였는가 | `results/evidence/vn2-ondemand-*` |
| StandbyPool | `results/observations/vn2-standby.json`의 `elapsed_ms` | `running 1` pre/post로 ready capacity 소비와 refill이 보였는가 | `results/evidence/vn2-standby-*` |
| Image Cache | `results/observations/vn2-standby-cached.json`의 `elapsed_ms` | cache request 후 same pool `1→0→1` 재구성이 반영되었는가 | `results/evidence/vn2-standby-cached-*` |

세 값은 순위를 매기거나 일반화하지 않습니다.

### 3) 해석 경계와 troubleshooting 포인트 기록

👁️ **설명**

이 워크숍은 세 경로를 한 번씩 관찰하는 참가자 동선입니다. 따라서 숫자를 더 빠른 순으로 줄 세우거나, 다른 구독·리전·시간대에 그대로 일반화하지 않습니다. 대신 `node_name`, standby pre/post, cache recycle, cleanup 여부를 evidence와 함께 설명합니다.

⚠️ **주의**

문제 해결은 저장해 둔 `results/evidence/` 파일을 기반으로 하고, 리소스 삭제 전까지 필요한 증적만 다시 엽니다. cleanup 이후에는 live cluster에서 같은 상태를 다시 보장할 수 없습니다.

### 4) exact RG cleanup 실행과 absence 확인

👁️ **설명**

cleanup는 항상 `results/workshop.env`에서 exact RG를 불러온 뒤 실행합니다. `--yes`를 빼면 script가 `type the resource group name exactly to continue` 를 요구해 scope를 한 번 더 확인합니다.

🟢 **실행**

```bash
source results/workshop.env
scripts/cleanup.sh --resource-group "$RG" --yes
az group exists --name "$RG"
```

📋 **예상 출력**

```text
false
```

👁️ **설명**

`az group exists`가 바로 `false`가 되지 않으면, 먼저 script가 남긴 경고를 읽습니다. fresh Cloud Shell session, missing kubeconfig, 또는 cluster unreachable 때문에 `WARNING: graceful cluster cleanup failed; continuing with standby pool and resource group deletion.` 이나 `Cleanup completed with warnings.` 가 보여도 billing-critical RG deletion 자체는 계속 진행되어야 합니다.

🟢 **실행**

```bash
az resource list --resource-group "$RG" --query '[].id' --output tsv
```

📋 **예상 출력**

- 남은 것이 없으면 비어 있는 출력이거나 script가 이미 `false`를 반환합니다.
- 남은 것이 있으면 exact residual resource IDs를 그대로 기록하고 같은 RG만 다시 정리합니다.

⚠️ **주의**

cleanup는 broad match가 아니라 exact RG 하나만 받습니다. `results/workshop.env`를 source하지 못한 상태에서 임의 이름이나 추측한 RG로 삭제를 시작하지 않습니다.

### 5) fresh Cloud Shell recovery와 missing state file fallback

👁️ **설명**

fresh Cloud Shell recovery의 첫 선택지는 항상 기존 `results/workshop.env`입니다. 이 파일이 있으면 다시 source 하고 4단계 cleanup 명령으로 돌아갑니다.

👁️ **설명**

만약 `results/workshop.env` 자체가 없다면, 아래 fallback 은 후보 RG를 찾는 용도만 사용합니다.

🟢 **실행**

```bash
cd ~/aci-vn2-performance-workshop
WORKSHOP_STATE="results/workshop.env"
mkdir -p results
az group list --query "[?starts_with(name, 'rg-vn2-hands-on-')].[name, location]" --output table

export RG='rg-vn2-hands-on-12345'
STATE_TMP="${WORKSHOP_STATE}.tmp.$$"
(
  umask 077
  printf "export RG='%s'\n" "$RG" >"$STATE_TMP"
)
chmod 600 "$STATE_TMP"
mv "$STATE_TMP" "$WORKSHOP_STATE"
source "$WORKSHOP_STATE"
```

👁️ **설명**

이 fallback은 exact RG를 새 shell에 다시 저장하기 위한 최소 절차입니다. cleanup 자체는 여전히 `scripts/cleanup.sh --resource-group "$RG" --yes`로만 실행하고, 필요하면 `az group show --name "$RG"`나 기존 evidence로 이름을 다시 대조합니다.

⚠️ **주의**

Never pass a wildcard or broad match into cleanup. Save the recovered exact RG back into results/workshop.env before deleting anything.

## 문제 해결

| 증상 | 확인 명령 | 조치 |
| --- | --- | --- |
| VN2 virtual node가 `NotReady`이거나 Pod가 `phase=Running`으로 가지 못한다 | `kubectl get nodes -L benchmark-path -o wide`, `kubectl get pods -A -o wide`, `kubectl get events -A --sort-by=.metadata.creationTimestamp \| tail -n 40` | 최신 `results/evidence/.../events.txt`, `pod-live.yaml`, `aci-inventory.json`을 먼저 열고 ondemand/standby release, delegated subnet, namespace 상태를 같은 RG 기준으로 다시 점검합니다 |
| standby pool이 healthy하지 않거나 ready가 비어 있다 | `./scripts/check-standby-pool.sh --resource-group "$RG" --name "$STANDBY_POOL" --expect-running 1 --timeout-seconds 1200 --interval-seconds 15`, `az standby-container-group-pool status --resource-group "$RG" --name "$STANDBY_POOL" --version latest --output json` | Azure CLI 원본의 `status.code`가 `HealthState/Degraded`인지 보고, checker 출력의 `{"health":"degraded"}` 또는 `running 1` 미달 여부를 그대로 기록한 뒤 RBAC, subnet, quota, region 상태를 확인합니다 |
| standby warm path에 fallback 흔적이 섞인다 | `grep -R --line-number -E 'StandbyPoolReuseFailure\|StandbyPoolExhaustedPool' results/observations results/evidence \| cat` | `StandbyPoolReuseFailure` 또는 `StandbyPoolExhaustedPool`가 보이면 해당 관찰은 warm reuse만 본 것이 아닐 수 있으므로 별도 메모로 분리하고 일반화하지 않습니다 |
| cached path에서 image pull 또는 네트워크 문제가 의심된다 | `LATEST="$(find results/evidence -maxdepth 1 -type d -name 'vn2-standby-cached-*' \| sort \| tail -n 1)"`, `sed -n '1,160p' "$LATEST/events.txt"`, `sed -n '1,160p' "$LATEST/pod-live.yaml"`, `cat "$LATEST/aci-inventory.json"` | `ImagePullBackOff`, `ErrImagePull`, quota 부족, NAT Gateway outbound 누락 중 무엇이 보이는지 구분하고, 원인을 수정한 뒤 필요한 cached observation만 다시 실행합니다 |
| cleanup 뒤에도 RG가 남아 있거나 경고가 이해되지 않는다 | `az group exists --name "$RG"`, `az resource list --resource-group "$RG" --query '[].id' --output tsv` | fresh Cloud Shell recovery로 exact RG를 다시 source 한 뒤 같은 RG만 재시도합니다. missing kubeconfig 때문에 cluster cleanup warning이 있더라도 residual resource IDs를 기록하고 billing-critical RG deletion을 끝까지 확인합니다 |

## 완료 체크포인트

- `results/observations/` 아래 세 JSON을 같은 형식으로 읽었다.
- 세 줄 worksheet에 `경로`, `관찰 시간`, `lifecycle에서 확인한 점`, `증적 경로`를 채웠다.
- 세 값은 순위를 매기거나 일반화하지 않습니다 라는 원칙을 다시 설명할 수 있다.
- `results/workshop.env`를 source 하는 경로와 missing state file fallback 경로를 구분할 수 있다.
- `scripts/cleanup.sh --resource-group "$RG" --yes`를 exact RG로 실행했다.
- `az group exists --name "$RG"` 결과가 최종적으로 `false`다.
- 필요하면 residual resource IDs를 다시 확인할 수 있다.

## 이전/다음

- 이전: [Module 06](./06-image-cache-hands-on.md)
- 다음: [README](../README.md)
