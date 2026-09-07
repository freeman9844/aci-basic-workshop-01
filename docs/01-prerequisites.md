# 01. 사전 검사와 참가 조건 확인

> Azure Cloud Shell Bash에서 구독, provider, feature/GA 상태, Standby Pool Resource Provider RBAC, preflight 결과를 한 흐름으로 점검합니다.


## 목표

이 모듈을 완료하면 다음을 할 수 있습니다.

- 전용 교육용 구독, Owner 권한, provider 등록, feature/GA 상태를 fail-fast로 확인할 수 있습니다.
- `Standby Pool Resource Provider` 서비스 주체에 필요한 세 가지 구독 역할을 정확히 부여할 수 있습니다.
- `./scripts/preflight.sh` 로 Azure CLI 2.76.0 이상, `Standard_D16s_v5`, 16 regional vCPU, 2 available container groups and 2 available StandardCores를 검증할 수 있습니다.
- `results/environment.json` 을 다음 모듈의 기준 입력으로 보존할 수 있습니다.

## 예상 소요 시간

15분

## 시작 전 상태

- Azure Portal Cloud Shell Bash에 로그인되어 있다.
- 워크숍 저장소가 `~/aci-vn2-performance-workshop` 또는 동등한 경로에 clone 되어 있다.
- 아직 workshop 리소스 그룹이나 AKS 클러스터를 만들지 않았다.
- 이 모듈은 워크숍 시작 전에 한 번, 실습 시작 직전에 한 번 다시 확인한다.


## 태그 범례

| 태그 | 의미 |
|------|------|
| 🟢 **실행** | 참가자가 직접 입력하거나 수행해야 하는 단계 |
| 👁️ **설명** | 왜 이 단계를 하는지 이해하기 위한 읽기 전용 안내 |
| 📋 **예상 출력** | 실행 결과와 비교할 기준 출력 |
| ⚠️ **주의** | 비용, 순서, 안전성, 계약 조건 안내 |


## 진행 순서

1. 현재 Azure 구독이 실습용 전용 구독인지 확인하고 provider를 미리 등록합니다.
2. 과거 `StandbyContainerGroupPoolPreview` feature가 필요했던 구독과 현재 GA 상태를 모두 안전하게 처리합니다.
3. `Standby Pool Resource Provider` 서비스 주체에 구독 범위 역할 세 개를 부여합니다.
4. `scripts/preflight.sh` 로 Azure CLI 2.76.0 이상, Owner 권한, provider 등록, 16 regional vCPU, 2 available container groups and 2 available StandardCores를 fail-fast 검증합니다.
5. `results/environment.json` 을 확인하고 다음 모듈에서 그대로 재사용합니다.
6. 모든 fail-fast 블록은 subshell keeps the interactive parent Cloud Shell safe 원칙으로 감쌉니다.


👁️ **설명**

아래 단계는 설명 → 실행 → 예상 출력 → 주의 순서로 읽습니다. 코드 블록은 순서를 바꾸지 말고, fail-fast로 멈추면 같은 단계에서 원인을 먼저 정리합니다.

⚠️ **주의**

선행 조건을 확인하지 못했거나 측정 상태가 불분명하면 다음 단계로 넘어가지 않습니다.


### 1) 워크숍 하루 전: provider 등록과 feature/GA 상태 확인

👁️ **설명**

아래 블록은 Cloud Shell Bash에서 그대로 실행할 수 있습니다. fail-fast 설정은 subshell 안에서만 켜고, `ResourceNotFound` 가 나오면 preview feature가 GA로 전환된 상태로 해석합니다.

🟢 **실행**

```bash
cd ~/aci-vn2-performance-workshop
mkdir -p results

( set -euo pipefail
  az account show --output table
  az provider register --namespace Microsoft.ContainerInstance --wait
  az provider register --namespace Microsoft.StandbyPool --wait

  FEATURE_ERROR_FILE="results/standby-feature-show.stderr.log"
  rm -f "$FEATURE_ERROR_FILE"

  set +e
  FEATURE_JSON="$(az feature show \
    --namespace Microsoft.StandbyPool \
    --name StandbyContainerGroupPoolPreview \
    --output json 2>"$FEATURE_ERROR_FILE")"
  FEATURE_RC=$?
  set -e

  if [[ "$FEATURE_RC" -eq 0 ]]; then
    FEATURE_STATE="$(jq -r '.properties.state' <<<"$FEATURE_JSON")"
    if [[ -z "$FEATURE_STATE" || "$FEATURE_STATE" == "null" ]]; then
      printf 'StandbyContainerGroupPoolPreview state could not be parsed.\n' >&2
      exit 1
    fi
    if [[ "$FEATURE_STATE" != "Registered" ]]; then
      az feature register \
        --namespace Microsoft.StandbyPool \
        --name StandbyContainerGroupPoolPreview
      printf 'Feature registration was requested; wait until it is Registered before the workshop.\n' >&2
      exit 1
    fi
  elif grep -qi 'ResourceNotFound' "$FEATURE_ERROR_FILE"; then
    printf 'The preview feature is no longer exposed; provider registration is the current GA gate.\n'
  else
    cat "$FEATURE_ERROR_FILE" >&2
    exit "$FEATURE_RC"
  fi

  rm -f "$FEATURE_ERROR_FILE"
)
```

👁️ **설명**

이 단계의 핵심은 역사적으로 `StandbyContainerGroupPoolPreview` 가 필요했던 구독과, 이제 feature 조회가 `ResourceNotFound` 로 끝나는 GA 구독을 둘 다 안전하게 처리하는 것입니다. `set -e` 복구도 subshell 안에서만 일어나므로 interactive parent Cloud Shell 옵션은 바뀌지 않습니다.

### 2) 워크숍 하루 전: Standby Pool Resource Provider 서비스 주체 RBAC 준비

👁️ **설명**

공개 MCR 이미지를 쓰더라도 `Standby Pool Resource Provider` 서비스 주체에는 구독 범위 역할 세 개가 필요합니다. VN2와 Standby Pool이 어느 단계에서 어떤 권한을 쓰는지까지 같이 기억해 둡니다.

🟢 **실행**

```bash
cd ~/aci-vn2-performance-workshop

( set -euo pipefail
  SUB_ID="$(az account show --query id -o tsv)"
  if [[ -z "$SUB_ID" ]]; then
    printf 'Subscription ID could not be resolved.\n' >&2
    exit 1
  fi
  SUB_SCOPE="/subscriptions/$SUB_ID"

  SP_OBJECT_ID="$(az ad sp list \
    --display-name 'Standby Pool Resource Provider' \
    --query '[0].id' -o tsv)"
  if ! test -n "$SP_OBJECT_ID"; then
    printf 'Standby Pool Resource Provider service principal was not found.\n' >&2
    exit 1
  fi

  for ROLE in \
    "Azure Container Instances Contributor Role" \
    "Standby Container Group Pool Contributor" \
    "Network Contributor"; do
    az role assignment create \
      --assignee-object-id "$SP_OBJECT_ID" \
      --assignee-principal-type ServicePrincipal \
      --role "$ROLE" \
      --scope "$SUB_SCOPE"
  done

  az role assignment list \
    --assignee-object-id "$SP_OBJECT_ID" \
    --scope "$SUB_SCOPE" \
    --output table
)
```

👁️ **설명**

Azure CLI는 built-in role 표시 이름을 부분 추정하지 않으므로 `Azure Container Instances Contributor Role` 처럼 현재 role definition의 정확한 이름을 그대로 써야 합니다.

필수 역할은 다음 세 가지입니다.

- `Azure Container Instances Contributor Role`: VN2가 ACI-backed virtual node 경로를 만들고 제거할 때 사용합니다.
- `Standby Container Group Pool Contributor`: Standby Pool이 ready instance를 만들고 유지할 때 사용합니다.
- `Network Contributor`: VN2와 Standby Pool이 workshop VNet/subnet 리소스를 연결할 때 필요합니다.

### 3) 실습 시작 직전: preflight 실행과 결과 확인

👁️ **설명**

이제 저장소가 제공하는 `scripts/preflight.sh` 로 참가자 환경을 다시 검증합니다.

🟢 **실행**

```bash
cd ~/aci-vn2-performance-workshop

( set -euo pipefail
  ./scripts/preflight.sh \
    --location koreacentral \
    --system-vm-size Standard_D16s_v5
  cat results/environment.json
)
```

👁️ **설명**

이 preflight의 active 계약은 workshop의 고정 system node 한 대와 최소 live ACI headroom만 검증합니다. `16 regional vCPU`는 `Standard_D16s_v5` system node 한 대를 위한 최소 여유분이고, `2 available container groups and 2 available StandardCores` 는 one ready standby instance plus one active or refilling workload instance를 동시에 수용하기 위한 hands-on 최소 안전선입니다. 이 수치는 production sizing recommendation이 아니라 참가자 실습을 fail-fast로 시작하기 위한 기준입니다.

📋 **예상 출력**

성공 예시는 다음과 같습니다.

```text
Preflight checks passed.
```

이후 `results/environment.json` 에 subscription, tenant, tool version, pinned VN2 chart version, hands_on_image digest가 기록되어 있어야 합니다.

실패 예시는 다음과 같습니다.

```text
ERROR: Microsoft.StandbyPool must be Registered; found NotRegistered
```

또는 feature가 아직 등록되지 않았다면 다음과 비슷한 메시지가 나옵니다.

```text
ERROR: StandbyContainerGroupPoolPreview is not registered. Run: az feature register --namespace Microsoft.StandbyPool --name StandbyContainerGroupPoolPreview
```

regional VM quota가 모자라면 다음처럼 멈춰야 정상입니다.

```text
ERROR: regional vCPU headroom is 15; need at least 16
```

⚠️ **주의**

Owner 권한이 없거나 provider 등록이 끝나지 않았다면 **다음 모듈로 진행하지 말고** 여기서 중단합니다. 이 워크숍은 fail-fast를 원칙으로 하므로 불완전한 선행 조건을 묵인하지 않습니다.

## 완료 체크포인트

- 현재 구독이 교육용 전용 구독으로 확인되었다.
- `Microsoft.ContainerInstance` 와 `Microsoft.StandbyPool` provider가 모두 Registered 상태다.
- `StandbyContainerGroupPoolPreview` 가 Registered 이거나, `ResourceNotFound` 로 GA 전환이 확인되었다.
- `Standby Pool Resource Provider` 서비스 주체에 세 가지 구독 역할이 부여되었다.
- Cloud Shell 또는 로컬 Bash 환경에서 필수 도구가 모두 실행된다.
- Azure CLI 2.76.0 이상이 설치되어 있다.
- `./scripts/preflight.sh --location koreacentral --system-vm-size Standard_D16s_v5` 가 성공했다.
- `results/environment.json` 파일이 생성되었다.
- fail-fast 블록이 끝난 뒤에도 interactive parent Cloud Shell 에는 persistent `set -e` / `set -u` 가 남지 않는다.
- quota 부족, Owner 누락, provider 미등록 시 어떤 항목을 먼저 고쳐야 하는지 메모했다.

## 트러블슈팅

| 증상 | 확인할 것 | 확인 명령 | 조치 |
| --- | --- | --- | --- |
| `Microsoft.StandbyPool must be Registered` | provider 등록 상태 | `az provider show --namespace Microsoft.StandbyPool --query registrationState -o tsv` | `az provider register --namespace Microsoft.StandbyPool --wait` 후 다시 실행 |
| `ResourceNotFound` 가 feature show 에서 반환됨 | GA 전환 여부 | `grep -i ResourceNotFound results/standby-feature-show.stderr.log` | 오류가 아니라면 provider Registered 만 확인하고 계속 진행 |
| `Standby Pool Resource Provider service principal was not found.` | Entra 조회 결과 | `az ad sp list --display-name 'Standby Pool Resource Provider' --output table` | display name 오타 여부 확인, 필요 시 관리자와 구독 상태 확인 |
| `Role 'Azure Container Instances Contributor' doesn't exist` 또는 role assignment create 가 실패함 | exact role definition name, 현재 사용자 권한 | `az role definition list --name 'Azure Container Instances Contributor Role' --output table` | `Azure Container Instances Contributor Role` 로 다시 실행하고, 그래도 실패하면 전용 교육용 구독 Owner 로 다시 로그인 |
| preflight가 quota 또는 SKU 부족으로 실패함 | Korea Central 가용량 | `./scripts/preflight.sh --location koreacentral --system-vm-size Standard_D16s_v5` | 16 regional vCPU와 2 available container groups and 2 available StandardCores를 먼저 확보한 뒤 다시 시작 |

ACI quota 증적이 필요하면 preflight와 같은 REST 경로를 직접 조회합니다. `az container list-usage` 는 현재 Azure CLI에 없으므로 사용하지 않습니다.
현재 API 응답은 `ContainerGroups` 를 노출할 수 있고, 과거 응답은 `StandardContainerGroups` 를 노출할 수 있습니다. In other words, the current API may expose `ContainerGroups`, and historical responses may expose `StandardContainerGroups`. No guessing beyond these two container group quota names is allowed.
Other ACI quota rows are informational only. Live Korea Central responses can also include `StandardSpotCores`, `StandardK80Cores`, `StandardP100Cores`, `StandardV100Cores`, `DedicatedContainerGroups`, `DedicatedCores`, `ConfidentialContainerGroups`, and `ConfidentialCores`, but preflight gates only on exactly one container group alias plus exactly one `StandardCores` row. That means unrelated rows must not block the workshop by themselves.
이 hands-on은 one ready standby instance plus one active or refilling workload instance를 동시에 감당할 최소 안전선만 확인하므로, preflight는 need at least 2 available container groups and 2 available StandardCores 기준으로만 통과시킵니다. 이 값은 참가자 실습 흐름을 위한 하한선이지 일반적인 production sizing recommendation이 아닙니다.

```bash
SUB_ID="$(az account show --query id -o tsv)"
az rest --method get --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.ContainerInstance/locations/koreacentral/usages?api-version=2025-09-01" --output json | jq '.value'
```

이전 모듈: [00. 개요](../README.md) · 다음 모듈: [02. AKS NAP 기반 환경 준비](./02-azure-foundation.md)
