# ACI Basic 워크숍

> 120분 동안 VN2 OnDemand, StandbyPool, Image Cache 세 경로를 hands-on으로 따라가며 각 경로에서 Pod 1개를 한 번 관찰하는 참가자용 워크숍입니다(성능 benchmark가 아닙니다). **전용 교육용 Azure 구독의 Owner 권한**을 전제로 하며, 운영 구독이나 공유 AKS 클러스터에서는 재현하지 마세요. 실습 중에는 `Standard_D16s_v5` fixed system node, VN2용 ACI sandbox, StandbyPool ready capacity 1, `cg` subnet의 NAT Gateway와 public IP가 함께 사용되므로, Module 07의 cleanup을 건너뛰면 과금이 계속될 수 있습니다.

---

## 아키텍처

```mermaid
flowchart TB
  user[Participant<br>Azure Cloud Shell Bash] --> scripts[Workshop scripts<br>preflight, install, run-hands-on, cleanup]
  scripts --> api[Single NAP-enabled AKS cluster API]

  subgraph cluster[Single NAP-enabled AKS cluster]
    system[Fixed system node<br>Standard_D16s_v5<br>VN2 infrastructure]
    ondemand[VN2 OnDemand virtual node<br>benchmark-path=ondemand]
    standby[VN2 Standby virtual node<br>benchmark-path=standby]
    cache[Image Cache request<br>vn2-image-cache namespace]
  end

  api --> ondemand
  api --> standby
  system --> ondemand
  system --> standby
  standby --> pool[StandbyPool<br>ready capacity 1]
  pool --> warm[Warm ACI sandbox]
  cache --> pool

  scripts --> observations[results/observations/*.json]
  scripts --> evidence[results/evidence/*]
```

한 개의 AKS API와 고정 system node 위에서 참가자는 세 가지 VN2 경로만 관찰합니다. Module 02는 foundation을 준비하고, Module 04-06은 각각 OnDemand, warm standby, cached standby path를 한 번씩 실행해 증적을 남깁니다.
실습에서 다루는 scenario ID는 `vn2-ondemand`, `vn2-standby`, `vn2-standby-cached` 입니다.

---

## 학습 목표

이 워크숍을 완료하면 다음을 할 수 있습니다.

1. NAP-enabled fixed-node AKS 위에 VN2 OnDemand와 StandbyPool 경로가 어떻게 공존하는지 설명할 수 있다.
2. Module 04-06에서 각 경로를 Pod 1개를 한 번 실행하는 방식으로 관찰하고, `results/observations/`와 `results/evidence/`를 확인할 수 있다.
3. `results/workshop.env`를 기준으로 fresh Cloud Shell에서도 같은 workshop state를 다시 불러올 수 있다.
4. StandbyPool ready capacity 1과 Image Cache 재구성(`1→0→1`)이 어떤 lifecycle 차이를 보여 주는지 정성적으로 설명할 수 있다.
5. 세 관찰값을 순위표로 바꾸지 않고 review한 뒤 exact RG cleanup까지 마무리할 수 있다.

---

## 사전 요구사항

| 항목 | 설명 |
|------|------|
| Azure Cloud Shell Bash 또는 동등한 Bash 환경 | 문서의 명령은 Bash 기준이며, fresh shell에서 다시 실행해도 같은 동작을 보장해야 합니다. |
| 전용 교육용 구독과 **Owner** 권한 | provider 등록, role assignment, cleanup, quota 확인을 같은 흐름으로 수행합니다. |
| quota headroom | `Standard_D16s_v5` system node 1대와 ACI 2-unit headroom(`2 available container groups` + `2 available StandardCores`)을 동시에 감당해야 합니다. |
| 실습 지역 | 문서와 스크립트는 `koreacentral` 기준으로 작성되어 있습니다. |
| 저장소 쓰기 권한 | `results/workshop.env`, `results/observations/`, `results/evidence/`를 계속 갱신하고 보존합니다. |
| 기본 도구 | `az`, `kubectl`, `helm`, `jq`, `python3`, `git`을 Module 01에서 다시 확인합니다. |

---

## 모듈 목차

필수 경로는 Module 01 → 07 순서로 진행합니다. Module 04에서 VN2 OnDemand, Module 05에서 StandbyPool, Module 06에서 Image Cache와 pool `1→0→1` lifecycle을 각각 직접 관찰한 뒤 Module 07에서 결과를 회고하고 전체 리소스를 cleanup합니다.

| # | 모듈 | 한 줄 설명 |
|---|------|------------|
| 00 | [워크숍 개요와 VN2 lifecycle](README.md) | 세 경로와 비-benchmark 관찰 기준을 이해합니다. |
| 01 | [사전 요구사항](docs/01-prerequisites.md) | D16, ACI 2-unit, provider, 권한을 검증합니다. |
| 02 | [Azure/AKS foundation](docs/02-azure-foundation.md) | NAP-enabled fixed-node AKS foundation을 생성합니다. |
| 03 | [Dual VN2와 StandbyPool](docs/03-install-dual-vn2.md) | OnDemand/Standby virtual node와 ready capacity 1을 준비합니다. |
| 04 | [VN2 OnDemand hands-on](docs/04-vn2-ondemand-hands-on.md) | Pod 1개의 create-to-Ready lifecycle을 관찰합니다. |
| 05 | [StandbyPool hands-on](docs/05-standby-pool-hands-on.md) | warm Pod 1개의 lifecycle과 pool refill을 관찰합니다. |
| 06 | [Image Cache hands-on](docs/06-image-cache-hands-on.md) | pool을 `1→0→1`로 재구성하고 cached Pod를 관찰합니다. |
| 07 | [회고, 트러블슈팅, cleanup](docs/07-limitations-troubleshooting-cleanup.md) | 세 관찰을 해석하고 전체 리소스를 삭제합니다. |

Module 03 이후 fresh shell에서 다시 들어올 때의 최소 시작점은 아래 두 줄입니다.

```bash
cd ~/aci-vn2-performance-workshop
source results/workshop.env
```

---

## 시간표

| 모듈 | 제목 | 예상 시간 |
|------|------|-----------|
| 00 | 워크숍 개요와 VN2 lifecycle | 5분 |
| 01 | 사전 요구사항 | 15분 |
| 02 | Azure/AKS foundation | 30분 |
| 03 | Dual VN2와 StandbyPool | 20분 |
| 04 | VN2 OnDemand hands-on | 10분 |
| 05 | StandbyPool hands-on | 15분 |
| 06 | Image Cache hands-on | 15분 |
| 07 | 회고, 트러블슈팅, cleanup | 10분 |
| | **워크숍 합계** | **120분** |

---

## 비용 개요

> 고정 통화 금액은 약속하지 않습니다. 구독, 리전, 실행 시간, 로그 보존량에 따라 달라집니다. 실습이 끝나면 반드시 Module 07의 cleanup을 수행하세요.

| 리소스 | 과금 기준 | 실습 관점 메모 |
|--------|-----------|----------------|
| AKS fixed system node | `Standard_D16s_v5` 실행 시간 | 두 VN2 release와 system Pod를 계속 호스팅합니다. |
| VN2 OnDemand path | 실제 Pod 요청 시 생성되는 ACI sandbox | Pod가 실행될 때마다 net-new 경로를 관찰합니다. |
| StandbyPool | warm standby capacity 유지 시간 | ready capacity 1을 계속 유지하므로 유휴 비용이 생길 수 있습니다. |
| Image Cache path | cache request + recycle 후 warm capacity | same pool을 `1→0→1`로 재구성한 뒤 cached path를 다시 관찰합니다. |
| NAT Gateway + public IP | 시간 + 데이터 처리량 | `cg` subnet outbound를 유지하는 동안 과금됩니다. |

전체 실습(약 120분) 기준 예상 비용: **USD $2–4 수준** (`Standard_D16s_v5` 노드가 대부분을 차지하며, ACI OnDemand/StandbyPool 사용량과 NAT Gateway/Public IP가 소액 더해집니다. 리전·실행 시간에 따라 상이). Module 07의 cleanup 수행을 권장합니다.

---

## 태그 범례

| 태그 | 의미 |
|------|------|
| 🟢 **실행** | 참가자가 직접 입력하거나 수행해야 하는 단계 |
| 👁️ **설명** | 개념 설명 또는 읽기 전용 안내 |
| 📋 **예상 출력** | 실행 결과와 비교할 기준 출력 |
| ⚠️ **주의** | 보안, 비용, 제약 사항 안내 |

---

## 트러블슈팅 색인

| 증상 | 참조 모듈 |
|------|-----------|
| provider, role assignment, quota preflight가 실패한다 | [docs/01-prerequisites.md#트러블슈팅](docs/01-prerequisites.md#트러블슈팅) |
| identity, VNet, NAT, AKS foundation 준비가 실패한다 | [docs/02-azure-foundation.md#트러블슈팅](docs/02-azure-foundation.md#트러블슈팅) |
| dual VN2 install, webhook ownership, standby discovery가 꼬인다 | [docs/03-install-dual-vn2.md#트러블슈팅](docs/03-install-dual-vn2.md#트러블슈팅) |
| VN2 OnDemand observation에서 phase 전환이 보이지 않는다 | [docs/04-vn2-ondemand-hands-on.md#트러블슈팅](docs/04-vn2-ondemand-hands-on.md#트러블슈팅) |
| same pool이 running 1을 채우지 못한다 | [docs/05-standby-pool-hands-on.md#트러블슈팅](docs/05-standby-pool-hands-on.md#트러블슈팅) |
| Image Cache recycle(`1→0→1`) 또는 cached observation 해석이 흔들린다 | [docs/06-image-cache-hands-on.md#트러블슈팅](docs/06-image-cache-hands-on.md#트러블슈팅) |
| review, fresh Cloud Shell recovery, cleanup 판단이 어렵다 | [docs/07-limitations-troubleshooting-cleanup.md#트러블슈팅](docs/07-limitations-troubleshooting-cleanup.md#트러블슈팅) |

---

## 참고 자료

- [Virtual nodes on Azure Container Instances](https://learn.microsoft.com/azure/container-instances/container-instances-virtual-nodes)
- [Standby pools for Azure Container Instances](https://learn.microsoft.com/azure/container-instances/container-instances-standby-pool-overview)
- [AKS automatic node provisioning overview](https://learn.microsoft.com/azure/aks/node-autoprovision)
- [선택 사항: 과거 성능 benchmark](docs/appendix/performance-benchmark.md)
