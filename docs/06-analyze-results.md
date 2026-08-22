# Module 06. 결과 분석과 해석

## 목표

`results/raw/` 의 raw JSON을 실제 summary schema로 다시 묶어 `results/summary.json`, `results/summary.csv`, `results/summary.md` 를 만들고, 개별 run 과 시나리오 aggregate 를 분리해서 해석합니다.

## 예상 소요 시간

20분

## 시작 전 상태

- Module 04와 Module 05에서 네 시나리오의 raw JSON이 모두 생성되었다.
- `results/raw/` 와 `results/diagnostics/` 아래의 실패/timeout/fallback evidence를 지우지 않았다.
- `vn2-ondemand`, `vn2-standby-uncached`, `vn2-standby-cached`, `aks` run 파일 이름이 고정 규칙을 따른다.

## 진행 순서

### 1) summary 산출물 생성

```bash
cd ~/aci-vn2-performance-workshop
python3 scripts/summarize-results.py \
  --input results/raw \
  --output-dir results
sed -n '1,220p' results/summary.md
head -n 2 results/summary.csv
```

정상 실행이면 표준 출력에 아래 한 줄이 보입니다.

```text
Successfully generated results/summary.json, results/summary.csv, and results/summary.md.
```

이 단계가 끝나면 `results/summary.json`, `results/summary.csv`, `results/summary.md` 세 파일이 동시에 존재해야 합니다.

### 2) 시나리오 aggregate 해석

`summary.json` 의 top-level 은 시나리오별 aggregate 입니다. 아래 명령은 실제 키 이름으로 aggregate 를 읽는 가장 짧은 방법입니다.

```bash
jq '."vn2-standby-cached"' results/summary.json
jq '.["vn2-standby-cached"] | {scenario, runs_count, ready_samples, failed_count, timeout_count, create_to_ready_ms, create_to_scheduled_ms, scheduled_to_ready_ms, batch_first_ready_ms, batch_all_ready_ms, pod_speedup_ratio, batch_speedup_ratio}' results/summary.json
```

여기서 읽는 핵심은 다음과 같습니다.

- `create->scheduled` 는 Pod가 처음 관찰된 뒤 스케줄 완료가 처음 관찰될 때까지이며 JSON 키는 `create_to_scheduled_ms` 입니다.
- `scheduled->ready` 는 스케줄 이후 `ContainersReady` 까지이며 JSON 키는 `scheduled_to_ready_ms` 입니다.
- `create->ready` 는 참가자가 가장 자주 비교하는 end-to-end 시간이며 JSON 키는 `create_to_ready_ms` 입니다.
- batch first-ready 는 `batch_first_ready_ms`, batch all-ready 는 `batch_all_ready_ms` 로 읽습니다.
- `ready_samples`, `failed_count`, `timeout_count` 는 성공 표본과 비성공 표본을 분리해 보여 주므로 failed/timeout sample을 aggregate 밖으로 숨기지 않습니다.
- `pod_speedup_ratio`, `batch_speedup_ratio` 는 `vn2-ondemand` median 대비 speed-up 입니다. 즉 OnDemand-relative speed-up 입니다.

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

- median 은 각 시나리오 15개 Pod 표본의 가운데 값입니다.
- nearest-rank p95 는 보간하지 않습니다. 샘플 수가 15개일 때도 nearest-rank p95 를 그대로 쓰며, interpolated percentile 로 다시 계산하지 않습니다.
- `speed-up` 은 `vn2-ondemand` median 을 분모/분자로 비교한 상대값이지 절대 SLA가 아닙니다.
- `failed_count`, `timeout_count` 가 0이 아니면 성공 Pod의 median 이 빨라도 같은 줄에서 함께 해석해야 합니다.
- regular AKS 수치는 이미 프로비저닝된 VM 노드와 warm image cache 영향을 받습니다. regular AKS warm image cache 결과를 VN2 burst 비용 비교로 읽으면 안 되며, burst 비용 비교가 아닙니다.
- 특히 regular AKS 는 노드가 계속 떠 있는 구조이므로 cache/cost 조건이 `vn2-ondemand` 또는 standby 경로와 다릅니다.

> **주의:** 이 워크숍의 p95와 speed-up 은 기술 통계입니다. **SLA가 아닙니다.** 실패/timeout sample을 숨기지 않습니다. 더 빠른 한 번의 run 도 제품 전체 성능 보장이 아닙니다.

## 완료 체크포인트

- `python3 scripts/summarize-results.py --input results/raw --output-dir results` 를 실행했다.
- `results/summary.json`, `results/summary.csv`, `results/summary.md` 가 모두 생성되었다.
- `create->scheduled`, `scheduled->ready`, `create->ready`, batch first-ready, batch all-ready 를 실제 키 이름과 함께 설명할 수 있다.
- `nearest-rank p95` 가 보간하지 않는 descriptive metric 임을 설명할 수 있다.
- `failed_count`, `timeout_count`, `non_ready_pods` 를 숨기지 않고 개별 run evidence 와 함께 읽었다.
- regular AKS warm image cache 결과를 standby/OnDemand burst 비용 판단과 섞지 않는다는 점을 설명할 수 있다.

## 문제 해결

| 증상 | 확인 명령 | 조치 |
| --- | --- | --- |
| summary 파일이 생성되지 않는다 | `find results/raw -maxdepth 1 -type f -name '*.json' | sort`, `python3 scripts/summarize-results.py --input results/raw --output-dir results` | raw JSON 자체가 없는지 먼저 확인하고, 다시 실행해 `Successfully generated results/summary.json, results/summary.csv, and results/summary.md.` 출력이 나오는지 본다 |
| aggregate 는 있는데 원인을 모르겠다 | `jq '.["vn2-standby-cached"] | {scenario, runs_count, ready_samples, failed_count, timeout_count, create_to_ready_ms, create_to_scheduled_ms, scheduled_to_ready_ms, batch_first_ready_ms, batch_all_ready_ms, pod_speedup_ratio, batch_speedup_ratio}' results/summary.json`, `jq '.["vn2-standby-cached"].evidence.runs[] | {run, metadata, batch, non_ready_pods}' results/summary.json` | aggregate 와 개별 run evidence 를 분리해서 본다. failure/timeout/fallback 을 aggregate 한 줄로 덮어쓰지 않는다 |
| cached 가 더 빠르지 않아 해석이 애매하다 | `sed -n '1,220p' results/summary.md`, `python3 -m json.tool results/raw/vn2-standby-cached-run-1.json | sed -n '1,220p'`, `python3 -m json.tool results/raw/vn2-standby-uncached-run-1.json | sed -n '1,220p'` | 한 run 의 최저값이 아니라 시나리오 aggregate 와 raw evidence 를 같이 보고, timeout/failure/sample 편차를 그대로 유지한 채 설명한다 |

## 이전/다음

- 이전: [Module 05](./05-standby-cache-benchmark.md)
- 다음: [Module 07](./07-limitations-troubleshooting-cleanup.md)
