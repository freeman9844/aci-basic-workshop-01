# 04. VN2 OnDemand hands-on 관찰

> Pod 1개를 한 번 실행해 VN2 OnDemand의 net-new ACI 준비와 phase transition을 관찰하고, `results/observations/`와 `results/evidence/`에 증적을 남깁니다.


## 목표

이 모듈을 완료하면 다음을 할 수 있습니다.

- `results/workshop.env`와 AKS context를 복구한 뒤 같은 `$RG`와 `$AKS`를 계속 사용할 수 있습니다.
- `./scripts/run-hands-on.sh`로 `vn2-ondemand`를 Pod 1개, 한 번 실행할 수 있습니다.
- `phase=Pending`에서 `phase=Running`으로 바뀌는 로그가 net-new ACI 준비와 어떻게 연결되는지 설명할 수 있습니다.
- `results/observations/vn2-ondemand.json`와 `results/evidence/` 아래 증적 디렉터리를 확인할 수 있습니다.
- 한 번의 hands-on 관찰 결과는 benchmark 또는 SLA가 아닙니다 라는 caveat를 그대로 유지할 수 있습니다.

## 예상 소요 시간

10분

## 시작 전 상태

- Module 03이 끝나 `results/workshop.env`에 `RG`, `AKS`, `STANDBY_POOL` 값이 저장되어 있다.
- `benchmark-path=ondemand` virtual node가 Ready다.
- `scripts/run-hands-on.sh`와 `manifests/hands-on-pod-template.yaml`이 현재 저장소 상태와 일치한다.
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
2. `vn2-ondemand`를 한 번 실행합니다.
3. `results/observations/`와 `results/evidence/`에서 observation JSON과 증적 경로를 확인합니다.
4. 이 값이 benchmark 또는 SLA가 아니라는 해석 제한을 기록합니다.

## 0. 세션 재연결 시 상태 복구 (선택)

<details>
<summary>fresh Cloud Shell에서 kubeconfig까지 다시 맞추는 명령 보기</summary>

👁️ **설명**

같은 shell을 계속 쓰고 있다면 이 절은 건너뜁니다. 새 Cloud Shell에서는 state file과 kubeconfig를 먼저 복구해야 `./scripts/run-hands-on.sh`가 정확한 클러스터를 향합니다.

🟢 **실행**

```bash
cd ~/aci-vn2-performance-workshop
source results/workshop.env
az aks get-credentials --resource-group "$RG" --name "$AKS" --overwrite-existing
printf 'RG=%s\nAKS=%s\n' "$RG" "$AKS"
```

📋 **예상 출력**

- 현재 workshop resource group과 AKS 이름이 다시 보입니다.
- kubeconfig가 같은 실습용 AKS를 가리키면 아래 단계로 바로 이어갈 수 있습니다.

</details>

👁️ **설명**

아래 단계는 설명 → 실행 → 예상 출력 → 주의 순서로 읽습니다. 코드 블록은 순서를 바꾸지 말고, fail-fast로 멈추면 같은 단계에서 원인을 먼저 정리합니다.

⚠️ **주의**

선행 조건을 확인하지 못했거나 observation 상태가 불분명하면 다음 단계로 넘어가지 않습니다.


### 1) workshop state와 kubeconfig 복구

👁️ **설명**

이 모듈의 active 실습은 Pod 1개를 한 번만 실행합니다. 먼저 `results/workshop.env`를 source하고 kubeconfig를 현재 AKS로 다시 맞춘 뒤, 같은 `$RG`를 기준으로 진행합니다.

🟢 **실행**

```bash
cd ~/aci-vn2-performance-workshop
source results/workshop.env
az aks get-credentials --resource-group "$RG" --name "$AKS" --overwrite-existing
```

📋 **예상 출력**

- `az aks get-credentials`가 현재 AKS context를 덮어씁니다.
- 오류가 없다면 다음 단계의 `./scripts/run-hands-on.sh` 명령을 그대로 실행할 수 있습니다.

### 2) Pod 1개 OnDemand observation 실행

👁️ **설명**

아래 명령은 `vn2-ondemand` 경로를 위해 namespace 하나를 임시로 만들고, Pod 1개를 한 번 실행한 뒤 observation JSON과 evidence를 기록하고 namespace를 정리합니다.

🟢 **실행**

```bash
./scripts/run-hands-on.sh \
  --scenario vn2-ondemand \
  --resource-group "$RG" \
  --output-dir results
```

📋 **예상 출력**

성공 예시는 다음과 비슷합니다.

```text
vn2-ondemand phase=Pending node=unscheduled ready=false elapsed=31ms
vn2-ondemand phase=Running node=virtual-node-ondemand ready=true elapsed=12345ms
vn2-ondemand Pod became Ready in 12.3 seconds.
This is one workshop observation, not a benchmark or SLA.
```

👁️ **설명**

`phase=Pending`은 Kubernetes에 Pod 요청이 등록되었지만 Ready가 아직 아닌 시점입니다. `phase=Running`까지 걸린 시간에는 VN2가 net-new ACI sandbox를 준비하고 container group을 초기화하는 과정이 포함됩니다.

⚠️ **주의**

이 단계는 비교 순위표를 만드는 절차가 아닙니다. 한 번의 hands-on 관찰 결과이며 benchmark 또는 SLA가 아닙니다.

### 3) observation JSON과 evidence 경로 확인

👁️ **설명**

active 관찰 결과는 `results/observations/`에 scenario별 JSON으로 남고, 상세 증적은 `results/evidence/` 아래 attempt별 디렉터리로 남습니다.

🟢 **실행**

```bash
jq '{scenario, status, node_name, elapsed_ms, cleanup}' \
  results/observations/vn2-ondemand.json
find results/evidence -maxdepth 1 -type d -name 'vn2-ondemand-*' | sort | tail -n 1
```

📋 **예상 출력**

- 첫 번째 명령은 `scenario`, `status`, `node_name`, `elapsed_ms`, `cleanup`만 뽑아 보여 줍니다.
- 두 번째 명령은 최신 evidence 디렉터리 하나를 출력합니다.

👁️ **설명**

최신 `results/evidence/vn2-ondemand-.../` 안에는 보통 `pod.yaml`, `pod.json`, `pod-live.yaml`, `events.txt`, `nodes.json`, `aci-inventory.json`이 함께 남습니다. `cleanup.status`가 `deleted`면 임시 namespace 정리까지 끝난 것입니다.

### 4) 해석할 때 적어 둘 문장

👁️ **설명**

참가자 메모에는 아래 세 줄을 그대로 남기면 해석이 흔들리지 않습니다.

- 이 값은 Pod 1개를 한 번 실행한 end-to-end observation입니다.
- `node_name`과 phase 출력은 OnDemand path가 net-new ACI 준비를 거쳤다는 증거입니다.
- 더 빠르거나 느린 한 번의 숫자만으로 일반화하지 않습니다. benchmark 또는 SLA가 아닙니다.

## 완료 체크포인트

- `source results/workshop.env` 와 `az aks get-credentials --resource-group "$RG" --name "$AKS" --overwrite-existing` 를 실행했다.
- `./scripts/run-hands-on.sh --scenario vn2-ondemand --resource-group "$RG" --output-dir results` 를 실행했다.
- `results/observations/vn2-ondemand.json` 을 확인했다.
- 최신 `results/evidence/` 디렉터리를 찾아 관련 증적 파일을 열 수 있다.
- `phase=Pending` 과 `phase=Running` 이 각각 무엇을 의미하는지 설명할 수 있다.
- 한 번의 hands-on 관찰 결과는 benchmark 또는 SLA가 아닙니다 라고 다시 말할 수 있다.

## 트러블슈팅

| 증상 | 확인 명령 | 조치 |
| --- | --- | --- |
| `results/workshop.env` 가 없거나 값이 비어 있다 | `ls results/workshop.env`, `sed -n '1,40p' results/workshop.env` | Module 03까지의 state file을 먼저 복구한 뒤 다시 source 합니다 |
| kubeconfig가 다른 AKS를 가리킨다 | `kubectl config current-context`, `az aks get-credentials --resource-group "$RG" --name "$AKS" --overwrite-existing` | kubeconfig를 다시 덮어쓴 뒤 재시도합니다 |
| Pod가 `phase=Running`으로 가지 못한다 | `find results/evidence -maxdepth 1 -type d -name 'vn2-ondemand-*' \| sort \| tail -n 1`, `kubectl get nodes -L benchmark-path -o wide` | 최신 evidence의 `events.txt` 와 `pod-live.yaml`을 먼저 확인한 뒤 VN2 OnDemand path 상태를 점검합니다 |
| `cleanup.status` 가 `failed`다 | `jq '.cleanup' results/observations/vn2-ondemand.json` | 실패 이유를 observation JSON에서 읽고 Module 07 cleanup 전에 namespace 잔여 여부를 다시 확인합니다 |

이전 모듈: [03. 이중 VN2 설치와 StandbyPool 준비](./03-install-dual-vn2.md) · 다음 모듈: [05. StandbyPool hands-on](./05-standby-pool-hands-on.md)
