# 06. 네 시나리오 결과 분석과 해석

> `results/raw`의 12개 raw JSON을 summary 산출물로 묶고, aggregate 통계와 개별 run evidence를 분리해 해석합니다.


## 목표

이 모듈을 완료하면 다음을 할 수 있습니다.

- `results/summary.json`, `results/summary.csv`, `results/summary.md` 를 같은 raw evidence에서 생성할 수 있습니다.
- `create_to_scheduled_ms`, `scheduled_to_ready_ms`, `create_to_ready_ms`, batch metric을 실제 키 이름으로 읽을 수 있습니다.
- `ready_samples`, `failed_count`, `timeout_count`, `non_ready_pods` 를 숨기지 않고 aggregate와 개별 run을 함께 해석할 수 있습니다.
- 12개 raw JSON과 all-success 기준 60개 Pod 표본을 같은 summary contract로 설명할 수 있습니다.
- Korea Central live rehearsal reference와 자신의 결과를 같은 ratio contract로 비교할 수 있습니다.

## 예상 소요 시간

15분

## 시작 전 상태

- Module 04와 Module 05에서 네 시나리오의 raw JSON이 모두 생성되었다.
- `results/raw/` 와 `results/diagnostics/` 아래의 실패/timeout/fallback evidence를 지우지 않았다.
- `aks-nap`, `vn2-ondemand`, `vn2-standby`, `vn2-standby-cached` run 파일 이름이 고정 규칙을 따른다.


## 태그 범례

| 태그 | 의미 |
|------|------|
| 🟢 **실행** | 참가자가 직접 입력하거나 수행해야 하는 단계 |
| 👁️ **설명** | 왜 이 단계를 하는지 이해하기 위한 읽기 전용 안내 |
| 📋 **예상 출력** | 실행 결과와 비교할 기준 출력 |
| ⚠️ **주의** | 비용, 순서, 안전성, 계약 조건 안내 |


## 진행 순서

1. `scripts/summarize-results.py` 로 summary 산출물을 생성합니다.
2. 네 시나리오 aggregate와 key metric 이름을 같은 기준으로 읽습니다.
3. 개별 run evidence, CSV/Markdown 산출물, live rehearsal reference를 함께 해석합니다.

## 0. 세션 재연결 시 상태 복구 (선택)

<details>
<summary>fresh Cloud Shell에서 summary 생성 전 상태를 다시 확인하는 명령 보기</summary>

👁️ **설명**

분석 단계에서는 raw evidence가 그대로 남아 있는지가 가장 중요합니다. 새 Cloud Shell이라면 state file을 다시 불러온 뒤 raw JSON 개수부터 확인합니다.

🟢 **실행**

```bash
cd ~/aci-vn2-performance-workshop
source results/workshop.env
find results/raw -maxdepth 1 -type f -name '*.json' | sort
```

📋 **예상 출력**

- raw JSON 목록이 보이면 summary 생성 전제 조건이 살아 있습니다.
- 파일이 부족하면 Module 04 또는 Module 05의 실패/재실행 기록부터 다시 확인합니다.

</details>

👁️ **설명**

아래 단계는 설명 → 실행 → 예상 출력 → 주의 순서로 읽습니다. 코드 블록은 순서를 바꾸지 말고, fail-fast로 멈추면 같은 단계에서 원인을 먼저 정리합니다.

⚠️ **주의**

선행 조건을 확인하지 못했거나 측정 상태가 불분명하면 다음 단계로 넘어가지 않습니다.


### 1) summary 산출물 생성

```bash
cd ~/aci-vn2-performance-workshop
python3 scripts/summarize-results.py \
  --input results/raw \
  --output-dir results
sed -n '1,220p' results/summary.md
head -n 2 results/summary.csv
```

📋 **예상 출력**

정상 실행이면 표준 출력에 아래 한 줄이 보입니다.

```text
Successfully generated results/summary.json, results/summary.csv, and results/summary.md.
```

이 단계가 끝나면 `results/summary.json`, `results/summary.csv`, `results/summary.md` 세 파일이 동시에 존재해야 합니다.

### 2) 시나리오 aggregate 해석

`summary.json`의 top-level은 다음 순서의 네 행입니다: `aks-nap`, `vn2-ondemand`, `vn2-standby`, `vn2-standby-cached`. 아래 명령은 OnDemand 기준선과 세 candidate aggregate를 실제 키 이름으로 확인합니다.

```bash
jq '.["aks-nap"]' results/summary.json
jq '.["vn2-ondemand"]' results/summary.json
jq '.["vn2-standby"]' results/summary.json
jq '.["vn2-standby-cached"]' results/summary.json
jq '.["vn2-standby-cached"] | {scenario, runs_count, ready_samples, failed_count, timeout_count, create_to_ready_ms, create_to_scheduled_ms, scheduled_to_ready_ms, batch_first_ready_ms, batch_all_ready_ms, pod_speedup_ratio, batch_speedup_ratio}' results/summary.json
```

여기서 읽는 핵심은 다음과 같습니다.

- `create->scheduled` 는 Pod가 처음 관찰된 뒤 스케줄 완료가 처음 관찰될 때까지이며 JSON 키는 `create_to_scheduled_ms` 입니다.
- `scheduled->ready` 는 스케줄 이후 `ContainersReady` 까지이며 JSON 키는 `scheduled_to_ready_ms` 입니다.
- `create->ready` 는 참가자가 가장 자주 비교하는 end-to-end 시간이며 JSON 키는 `create_to_ready_ms` 입니다.
- batch first-ready 는 `batch_first_ready_ms`, batch all-ready 는 `batch_all_ready_ms` 로 읽습니다.
- `ready_samples`, `failed_count`, `timeout_count` 는 성공 표본과 비성공 표본을 분리해 보여 주므로 failed/timeout sample을 aggregate 밖으로 숨기지 않습니다. median 은 `ready_samples` 기준으로 계산합니다.
- `pod_speedup_ratio` 는 `create_to_ready_ms` median 기준 `vn2-ondemand` 대비 speed-up 입니다.
- `batch_speedup_ratio` 는 `batch_all_ready_ms` median 기준 `vn2-ondemand` 대비 speed-up 입니다. first-ready 기준이 아닙니다.

상대비 공식은 **OnDemand median / candidate median**입니다. 1보다 크면 candidate가 OnDemand보다 빠르고, 1보다 작으면 느립니다. `aks-nap`, `vn2-standby`, `vn2-standby-cached` 모두 같은 `vn2-ondemand` median을 기준으로 읽습니다. 이 비율은 서로 다른 compute lifecycle을 단순화한 기술 통계이므로 절대 성능 보장으로 해석하지 않습니다.

### 3) 개별 run evidence 해석

aggregate 수치만 보면 fallback contamination, image pull, timeout 원인을 놓칩니다. 개별 run 은 `evidence.runs[]` 아래에 그대로 남습니다.

```bash
jq '.["vn2-standby-cached"].evidence.runs[] | {run, metadata, batch, non_ready_pods}' results/summary.json
python3 -m json.tool results/raw/vn2-standby-cached-run-1.json | sed -n '1,220p'
```

실제로 확인해야 할 포인트는 다음과 같습니다.

- `metadata` 는 raw run 의 top-level 추가 필드를 그대로 보존합니다. 예를 들어 pool 상태나 fallback reason 이 raw 에 있었다면 `evidence.runs[].metadata` 에 남습니다.
- `non_ready_pods` 는 timeout/failed Pod만 따로 다시 묶어 보여 줍니다.
- `batch.first_ready_ms`, `batch.all_ready_ms`, `batch.timeout_ms` 를 함께 읽어야 개별 run 의 burst 체감과 전체 완료 시간을 혼동하지 않습니다.
- 같은 시나리오라도 개별 run 에서 더 빠른 한 번이 나왔다고 제품 전체 성능 보장이 아닙니다. 시나리오 aggregate 와 raw evidence 를 같이 봐야 합니다.

### 4) CSV/Markdown 산출물과 실제 컬럼명 확인

`summary.csv` 는 시나리오 한 줄 요약용이고, `summary.md` 는 워크숍 공유용입니다. CSV header 는 아래와 정확히 일치합니다.

```text
scenario,runs_count,ready_samples,failed_count,timeout_count,pod_median_ms,pod_p95_ms,pod_min_ms,pod_max_ms,batch_first_ready_median_ms,batch_all_ready_median_ms,pod_speedup_ratio,batch_speedup_ratio,evidence_json
```

따라서 다음처럼 읽으면 aggregate 와 evidence 가 어디에 있는지 즉시 구분됩니다.

- `summary.csv`: 비교표용. aggregate 숫자와 `evidence_json` 한 칼럼이 있습니다.
- `summary.md`: 사람이 읽는 요약표와 `## 증거` 블록이 있습니다.
- `summary.json`: 자동 검토용. 개별 metric 구조를 가장 정확하게 보존합니다.

### 5) median, nearest-rank p95, speed-up 를 해석할 때의 원칙

- median 은 `ready_samples` 기준으로 계산합니다. all-success 시나리오에서는 `ready_samples=15` 이므로 15개 성공 Pod 표본의 가운데 값입니다.
- nearest-rank p95 는 보간하지 않습니다. 샘플 수가 15개일 때도 nearest-rank p95 를 그대로 쓰며, interpolated percentile 로 다시 계산하지 않습니다.
- `pod_speedup_ratio` 는 `create_to_ready_ms` median 기준, `batch_speedup_ratio` 는 `batch_all_ready_ms` median 기준입니다. `speed-up` 은 `vn2-ondemand` median 을 분모/분자로 비교한 상대값이지 절대 SLA가 아닙니다.
- `failed_count`, `timeout_count` 가 0이 아니면 성공 Pod의 median 이 빨라도 같은 줄에서 함께 해석해야 합니다.
- `aks-nap`은 미리 실행 중인 VM node가 아니라 node/NodeClaim 0에서 시작하는 VM scale-out 전체 경로입니다. VM allocation, bootstrap, node registration, image pull과 container start가 Pod Ready latency에 포함됩니다.
- `vn2-ondemand`는 공통 median baseline입니다. NAP와 Standby 두 경로의 lifecycle과 비용 조건이 다르므로 비율만으로 운영 선택을 결정하지 않습니다.
- NAP consolidation은 run 뒤 zero-capacity reset에 포함되지만 Pod Ready latency에는 포함되지 않습니다.

⚠️ **주의**

이 워크숍의 p95와 speed-up 은 기술 통계입니다. **SLA가 아닙니다.** 실패/timeout sample을 숨기지 않습니다. 더 빠른 한 번의 run 도 제품 전체 성능 보장이 아닙니다.

### 6) Korea Central live rehearsal reference

2026-08-23 Korea Central에서 5 Pods × 3회씩 측정한 live reference가 게시되어 있습니다.

| Scenario | Pod create→ready median | Batch all-ready median | Pod ratio | Batch ratio |
| --- | ---: | ---: | ---: | ---: |
| `aks-nap` | 84,590.3 ms | 85,613.0 ms | 0.620x | 0.635x |
| `vn2-ondemand` | 52,422.3 ms | 54,383.4 ms | baseline | baseline |
| `vn2-standby` | 8,216.7 ms | 21,153.3 ms | 6.380x | 2.571x |
| `vn2-standby-cached` | 5,431.7 ms | 8,067.0 ms | 9.651x | 6.741x |

[Korea Central 2026-08-23 live rehearsal reference](./reference/korea-central-2026-08-23.md)에는 환경과 p95, NAP 0→1→0 lifecycle, StandbyPool `healthy`/`running=5`, cache 5→0→5 recycle, 실패/timeout/fallback evidence가 있습니다. 원본 정밀도와 ratio contract는 [reference JSON](./reference/korea-central-2026-08-23.json)에 있습니다.

이 값은 특정 rehearsal의 reference이며 SLA나 성능 보장이 아닙니다. 자신의 결과를 reference와 억지로 맞추지 말고 raw evidence, 실패/timeout, Azure region/SKU/capacity 조건을 함께 기록하십시오.

## 완료 체크포인트

- `python3 scripts/summarize-results.py --input results/raw --output-dir results` 를 실행했다.
- `results/summary.json`, `results/summary.csv`, `results/summary.md` 가 모두 생성되었다.
- `create->scheduled`, `scheduled->ready`, `create->ready`, batch first-ready, batch all-ready 를 실제 키 이름과 함께 설명할 수 있다.
- `nearest-rank p95` 가 보간하지 않는 descriptive metric 임을 설명할 수 있다.
- `failed_count`, `timeout_count`, `non_ready_pods` 를 숨기지 않고 개별 run evidence 와 함께 읽었다.
- `aks-nap`, `vn2-standby`, `vn2-standby-cached`가 모두 VN2 OnDemand median baseline을 사용하는 이유를 설명할 수 있다.
- 새 live reference의 환경과 NAP/Standby/cache lifecycle 조건을 함께 설명할 수 있다.

## 문제 해결

| 증상 | 확인 명령 | 조치 |
| --- | --- | --- |
| summary 파일이 생성되지 않는다 | `find results/raw -maxdepth 1 -type f -name '*.json' | sort`, `python3 scripts/summarize-results.py --input results/raw --output-dir results` | raw JSON 자체가 없는지 먼저 확인하고, 다시 실행해 `Successfully generated results/summary.json, results/summary.csv, and results/summary.md.` 출력이 나오는지 본다 |
| aggregate 는 있는데 원인을 모르겠다 | `jq '.["vn2-standby-cached"] | {scenario, runs_count, ready_samples, failed_count, timeout_count, create_to_ready_ms, create_to_scheduled_ms, scheduled_to_ready_ms, batch_first_ready_ms, batch_all_ready_ms, pod_speedup_ratio, batch_speedup_ratio}' results/summary.json`, `jq '.["vn2-standby-cached"].evidence.runs[] | {run, metadata, batch, non_ready_pods}' results/summary.json` | aggregate 와 개별 run evidence 를 분리해서 본다. failure/timeout/fallback 을 aggregate 한 줄로 덮어쓰지 않는다 |
| cached 가 더 빠르지 않아 해석이 애매하다 | `sed -n '1,220p' results/summary.md`, `python3 -m json.tool results/raw/vn2-standby-cached-run-1.json | sed -n '1,220p'`, `python3 -m json.tool results/raw/vn2-standby-run-1.json | sed -n '1,220p'` | 한 run 의 최저값이 아니라 시나리오 aggregate 와 raw evidence 를 같이 보고, timeout/failure/sample 편차를 그대로 유지한 채 설명한다 |

## 이전/다음

- 이전: [Module 05](./05-standby-cache-benchmark.md)
- 다음: [Module 07](./07-limitations-troubleshooting-cleanup.md)
