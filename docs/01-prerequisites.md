# Module 01. 사전 검사와 참가 조건 확인

## 목표

참가자가 워크숍 시작 전에 전용 교육용 구독, Owner 권한, 필수 도구 버전, provider 및 feature 등록, Korea Central quota 상태를 한 번에 점검하도록 합니다.

## 예상 소요 시간

15분

## 시작 전 상태

- Azure Portal Cloud Shell Bash에 로그인되어 있다.
- 워크숍 저장소가 `~/aci-vn2-performance-workshop` 또는 동등한 경로에 clone 되어 있다.
- 아직 workshop 리소스 그룹이나 AKS 클러스터를 만들지 않았다.

## 진행 순서

1. 현재 Azure 구독이 실습용 전용 구독인지 확인합니다.
2. `az`, `kubectl`, `helm`, `jq`, `python3`, `git` 사용 가능 여부를 점검합니다.
3. `Microsoft.ContainerInstance`, `Microsoft.StandbyPool`, preview feature 또는 GA 전환 상태를 확인합니다.
4. Korea Central의 AKS VM SKU와 ACI quota가 실습 요구사항을 만족하는지 검증합니다.
5. `results/environment.json`을 생성해 이후 모듈에서 같은 기준값을 재사용합니다.

```bash
cd ~/aci-vn2-performance-workshop
az account show --output table
./scripts/preflight.sh --location koreacentral --vm-size Standard_D8s_v5
cat results/environment.json
```

예상 결과는 “Preflight checks passed.” 메시지와 함께 subscription, tenant, tool version, pinned VN2 chart version, benchmark image digest가 `results/environment.json`에 기록되는 것입니다.

Owner 권한이 없거나 provider 등록이 끝나지 않았다면 Module 02로 진행하지 말고 여기서 중단합니다. 이 워크숍은 fail-fast를 원칙으로 하므로 불완전한 선행 조건을 묵인하지 않습니다.

## 완료 체크포인트

- 현재 구독이 교육용 전용 구독으로 확인되었다.
- Cloud Shell 또는 로컬 Bash 환경에서 필수 도구가 모두 실행된다.
- `./scripts/preflight.sh --location koreacentral --vm-size Standard_D8s_v5` 가 성공했다.
- `results/environment.json` 파일이 생성되었다.
- quota 부족, Owner 누락, provider 미등록 시 어떤 항목을 먼저 고쳐야 하는지 메모했다.

## 이전/다음

- 이전: [README](../README.md)
- 다음: [Module 02](./02-azure-foundation.md)
