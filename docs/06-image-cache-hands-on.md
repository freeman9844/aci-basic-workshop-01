# 06. Image Cache hands-on 관찰

> Image Cache request를 적용하고 같은 standby pool을 `1→0→1`로 재구성한 뒤, Pod 1개를 한 번 cached path로 실행해 `results/observations/`와 `results/evidence/`에 증적을 남깁니다.


## 목표

이 모듈을 완료하면 다음을 할 수 있습니다.

- `results/workshop.env`에서 같은 `$RG`, `$AKS`, `$STANDBY_POOL` 상태를 복구할 수 있습니다.
- `manifests/image-cache-pod.yaml`을 `vn2-hands-on-image-cache` 이름으로 적용할 수 있습니다.
- 같은 standby pool을 `--max-ready-capacity 1 → 0 → 1` 순서로 재구성하고 각 상태를 검증할 수 있습니다.
- `./scripts/run-hands-on.sh`로 `vn2-standby-cached`를 Pod 1개, 한 번 실행할 수 있습니다.
- Image Cache annotation이 cache request/template input 이며, 한 번의 관찰만으로는 보편적인 개선을 증명할 수 없습니다 라고 설명할 수 있습니다.

## 예상 소요 시간

15분

## 시작 전 상태

- Module 05가 끝나 `results/observations/vn2-standby.json`과 관련 `results/evidence/`가 남아 있다.
- `results/workshop.env`에 `RG`, `AKS`, `STANDBY_POOL` 값이 저장되어 있다.
- same standby pool이 healthy/running 1로 복구되어 있다.
- `vn2-image-cache` namespace는 없거나, 있어도 다음 apply로 같은 request를 갱신할 수 있다.


## 태그 범례

| 태그 | 의미 |
|------|------|
| 🟢 **실행** | 참가자가 직접 입력하거나 수행해야 하는 단계 |
| 👁️ **설명** | 왜 이 단계를 하는지 이해하기 위한 읽기 전용 안내 |
| 📋 **예상 출력** | 실행 결과와 비교할 기준 출력 |
| ⚠️ **주의** | 비용, 순서, 안전성, 해석 제한 안내 |


## 진행 순서

1. `results/workshop.env`와 kubeconfig를 복구합니다.
2. Image Cache request Pod를 적용하고 live YAML을 확인합니다.
3. 같은 standby pool을 `1→0→1`로 재구성하고 running 0, running 1을 각각 확인합니다.
4. `vn2-standby-cached`를 한 번 실행하고 observation JSON과 evidence를 읽습니다.

## 0. 세션 재연결 시 상태 복구 (선택)

<details>
<summary>fresh Cloud Shell에서 cached hands-on 상태를 다시 맞추는 명령 보기</summary>

👁️ **설명**

Image Cache apply와 cached observation은 `kubectl`과 `az`를 모두 사용합니다. 새 Cloud Shell이라면 state file과 kubeconfig를 먼저 복구합니다.

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

cached hands-on은 same pool을 의도적으로 `1→0→1`로 다시 채우는 절차를 포함합니다. 순서를 바꾸면 cache request가 어떤 capacity에 반영되었는지 설명하기 어려워집니다.


### 1) workshop state와 kubeconfig 복구

🟢 **실행**

```bash
cd ~/aci-vn2-performance-workshop
source results/workshop.env
az aks get-credentials --resource-group "$RG" --name "$AKS" --overwrite-existing
```

### 2) Image Cache request 적용

👁️ **설명**

`manifests/image-cache-pod.yaml`의 annotation `microsoft.containerinstance.virtualnode.imagecachepod: "true"` 는 cached observation 자체가 아니라 cache request/template input 입니다. 먼저 request Pod를 적용하고 live YAML로 이름과 annotation을 확인합니다.

🟢 **실행**

```bash
source results/workshop.env

kubectl create namespace vn2-image-cache --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f manifests/image-cache-pod.yaml
kubectl get pod -n vn2-image-cache vn2-hands-on-image-cache -o yaml
```

📋 **예상 출력**

- namespace apply가 성공합니다.
- `vn2-hands-on-image-cache` Pod YAML에서 annotation과 pinned image를 확인할 수 있습니다.

### 3) same pool을 `1→0→1`로 재구성

👁️ **설명**

uncached observation에서 사용했던 기존 ready capacity와 새 cache request가 섞이지 않도록 same pool을 1에서 0으로 줄였다가 다시 1로 복구합니다.

🟢 **실행**

```bash
az standby-container-group-pool update \
  --resource-group "$RG" \
  --name "$STANDBY_POOL" \
  --max-ready-capacity 0 \
  --refill-policy always

./scripts/check-standby-pool.sh \
  --resource-group "$RG" \
  --name "$STANDBY_POOL" \
  --expect-running 0 \
  --timeout-seconds 1200 \
  --interval-seconds 15

az standby-container-group-pool update \
  --resource-group "$RG" \
  --name "$STANDBY_POOL" \
  --max-ready-capacity 1 \
  --refill-policy always

./scripts/check-standby-pool.sh \
  --resource-group "$RG" \
  --name "$STANDBY_POOL" \
  --expect-running 1 \
  --timeout-seconds 1200 \
  --interval-seconds 15
```

📋 **예상 출력**

- 첫 번째 checker는 running 0을 확인합니다.
- 두 번째 checker는 running 1을 확인합니다.

⚠️ **주의**

running 1로 돌아왔다고 해서 보편적인 개선이 자동으로 증명되는 것은 아닙니다. 이 단계는 cache request가 반영된 새 ready capacity를 준비하기 위한 재구성 절차입니다.

### 4) Pod 1개 cached observation 실행

👁️ **설명**

이제 cached standby path에서 Pod 1개를 한 번 실행합니다. observation JSON에는 standby pre/post 상태와 cleanup 결과가 함께 저장됩니다.

🟢 **실행**

```bash
./scripts/run-hands-on.sh \
  --scenario vn2-standby-cached \
  --resource-group "$RG" \
  --standby-pool "$STANDBY_POOL" \
  --output-dir results
```

📋 **예상 출력**

성공 예시는 다음과 비슷합니다.

```text
vn2-standby-cached phase=Pending node=virtual-node-standby ready=false elapsed=30ms
vn2-standby-cached phase=Running node=virtual-node-standby ready=true elapsed=3210ms
vn2-standby-cached Pod became Ready in 3.2 seconds.
This is one workshop observation, not a benchmark or SLA.
```

### 5) observation JSON과 evidence 경로 확인

👁️ **설명**

active 관찰 결과는 `results/observations/`에 scenario별 JSON으로, 세부 파일은 `results/evidence/` 아래 attempt별 디렉터리로 남습니다.

🟢 **실행**

```bash
jq '{scenario, status, elapsed_ms, standby_pool, cleanup}' \
  results/observations/vn2-standby-cached.json
find results/evidence -maxdepth 1 -type d -name 'vn2-standby-cached-*' | sort | tail -n 1
```

📋 **예상 출력**

- observation JSON에서 `standby_pool.pre.running`과 `standby_pool.post.running`을 다시 확인할 수 있습니다.
- 두 번째 명령은 최신 cached evidence 디렉터리 하나를 출력합니다.

👁️ **설명**

최신 `results/evidence/vn2-standby-cached-.../` 안에는 `standby-pre.json`, `standby-post.json`, `pod.json`, `pod-live.yaml`, `events.txt`, `nodes.json`, `aci-inventory.json` 같은 증적이 남습니다. `vn2-image-cache` namespace와 `vn2-hands-on-image-cache` Pod는 final cleanup 전까지 남겨 두었다가 Module 07에서 정리합니다.

Image Cache annotation은 cache request/template input 입니다. cached path에서 한 번 더 빨라 보이거나 비슷해 보여도, 한 번의 관찰만으로는 보편적인 개선을 증명할 수 없습니다. 이 값 역시 benchmark 또는 SLA가 아닙니다.

## 완료 체크포인트

- `kubectl apply -f manifests/image-cache-pod.yaml` 를 실행했다.
- `kubectl get pod -n vn2-image-cache vn2-hands-on-image-cache -o yaml` 로 live YAML을 확인했다.
- same pool에 `--max-ready-capacity 0` 과 `--max-ready-capacity 1` 업데이트를 모두 적용했다.
- `./scripts/check-standby-pool.sh` 로 `--expect-running 0` 과 `--expect-running 1` 을 모두 확인했다.
- `./scripts/run-hands-on.sh --scenario vn2-standby-cached --resource-group "$RG" --standby-pool "$STANDBY_POOL" --output-dir results` 를 실행했다.
- `results/observations/vn2-standby-cached.json`과 최신 `results/evidence/` 디렉터리를 확인했다.
- Image Cache annotation이 cache request/template input 이며, 한 번의 관찰만으로는 보편적인 개선을 증명할 수 없습니다 라고 설명할 수 있다.

## 트러블슈팅

| 증상 | 확인 명령 | 조치 |
| --- | --- | --- |
| cache request Pod가 보이지 않는다 | `kubectl get pod -n vn2-image-cache -o wide`, `kubectl get pod -n vn2-image-cache vn2-hands-on-image-cache -o yaml` | namespace apply와 manifest apply를 다시 확인하고 annotation/name이 올바른지 점검합니다 |
| same pool이 running 0 또는 running 1로 돌아오지 않는다 | `./scripts/check-standby-pool.sh --resource-group "$RG" --name "$STANDBY_POOL" --expect-running 0 --timeout-seconds 1200 --interval-seconds 15`, `./scripts/check-standby-pool.sh --resource-group "$RG" --name "$STANDBY_POOL" --expect-running 1 --timeout-seconds 1200 --interval-seconds 15` | update 명령과 checker JSON을 함께 보고 refill 완료 후 다음 단계로 진행합니다 |
| cached observation 뒤에도 해석이 불안하다 | `jq '.standby_pool' results/observations/vn2-standby-cached.json` | pool이 `1→0→1`로 재구성되었는지와 pre/post running 1이 남았는지 먼저 확인합니다 |
| cleanup 전 image-cache 리소스를 따로 지우고 싶다 | `kubectl get pod -n vn2-image-cache vn2-hands-on-image-cache -o yaml` | 임의로 지우기보다 Module 07 cleanup 흐름에서 정리해 evidence와 cleanup scope를 함께 보존합니다 |

이전 모듈: [05. StandbyPool hands-on](./05-standby-pool-hands-on.md) · 다음 모듈: [07. 회고와 cleanup](./07-limitations-troubleshooting-cleanup.md)
