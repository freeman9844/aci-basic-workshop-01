# Module 07. 제약, 트러블슈팅, 정리

## 목표

워크숍의 해석 한계와 대표 오류 증상을 정리하고, 실습 비용이 남지 않도록 리소스 그룹과 관련 리소스를 모두 정리합니다.

## 예상 소요 시간

10분

## 시작 전 상태

- Module 06까지 완료되어 필요한 결과 파일을 모두 확보했다.
- 결과를 보관할 위치가 정해졌고 `results/` 산출물 복사가 끝났다.
- 정리 직후에도 리소스 존재 여부를 다시 확인할 수 있도록 Azure 세션이 유지되고 있다.

## 진행 순서

1. 결과 해석의 한계(샘플 수, 지역 편차, quota, platform 상태)를 다시 확인합니다.
2. 대표 오류별 확인 명령과 재시도 기준을 정리합니다.
3. image-cache Pod, benchmark namespace, Helm release, standby pool 관련 리소스, workshop RG 순서로 cleanup를 실행합니다.
4. `az group exists` 와 잔여 resource 확인으로 과금 리소스가 남지 않았는지 검증합니다.

```bash
cd ~/aci-vn2-performance-workshop
kubectl get events -A --sort-by=.lastTimestamp | tail -n 40
./scripts/cleanup.sh --resource-group "$WORKSHOP_RG" --yes
az group exists --name "$WORKSHOP_RG"
```

### 자주 만나는 증상

- standby pool health가 `degraded` 로 내려가면 raw evidence를 보존한 뒤 pool status와 quota를 먼저 확인합니다.
- `benchmark timeout` 이 발생하면 diagnostics 디렉터리의 `kubectl describe`, `kubectl events`, `az container list` 결과를 같이 읽습니다.
- ACI quota 부족, delegated subnet 누락, NAT Gateway 미연결은 재시도 전에 수정해야 하는 구조적 오류입니다.
- 결과가 기대보다 느려도 outlier를 삭제하지 말고 환경 metadata와 함께 해석합니다.

이 모듈은 cleanup를 옵션으로 취급하지 않습니다. 이 워크숍은 warm standby capacity를 유지하는 구조이므로 정리 누락이 곧 비용 누락입니다.

## 완료 체크포인트

- limitation과 troubleshooting 포인트를 팀에 설명할 수 있다.
- `./scripts/cleanup.sh --resource-group "$WORKSHOP_RG" --yes` 를 실행했다.
- `az group exists --name "$WORKSHOP_RG"` 결과가 `false` 다.
- 잔여 resource ID가 없음을 확인했다.
- 실습 비용이 더 이상 누적되지 않는 상태로 종료했다.

## 이전/다음

- 이전: [Module 06](./06-analyze-results.md)
- 다음: [README](../README.md)
