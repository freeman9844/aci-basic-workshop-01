# Korea Central VN2 hands-on rehearsal - 2026-08-26

> 한 번의 hands-on 관찰 결과이며 benchmark 또는 SLA가 아닙니다.

## 환경

- Region: `koreacentral`
- StandbyPool initial running: `1`
- Cached exercise recycle: `1→0→1`

## observations

| scenario | status | create-to-Ready | node | local evidence path |
| --- | --- | ---: | --- | --- |
| `vn2-ondemand` | `ready` | 88714 ms | `vn2-ondemand-0` | `results/evidence/vn2-ondemand-20260826t092700z-1748262` |
| `vn2-standby` | `ready` | 21371 ms | `vn2-standby-0` | `results/evidence/vn2-standby-20260826t092922z-1749295` |
| `vn2-standby-cached` | `ready` | 16773 ms | `vn2-standby-0` | `results/evidence/vn2-standby-cached-20260826t093202z-1750023` |

각 행은 독립된 한 번의 관찰입니다. 행 사이의 순위, 배수, 일반화된 성능 결론을 계산하지 않습니다.

## lifecycle checkpoints

- VN2 OnDemand Pod가 Ready에 도달했습니다.
- StandbyPool은 workload가 실행 중일 때 pre/post `running=1`을 확인했습니다.
- Image Cache request 후 같은 pool을 `1→0→1`로 재구성했습니다.

## cleanup

- Resource group: `rg-vn2-hands-on-17731`
- resource group exists: false
