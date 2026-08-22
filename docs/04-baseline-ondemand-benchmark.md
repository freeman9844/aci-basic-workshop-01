# Module 04. 기준선과 OnDemand 측정 실행

## 목표

같은 benchmark Pod template로 regular AKS 경로와 `VN2 OnDemand` 경로를 각각 3회씩 실행해 `aks` 와 `vn2-ondemand` raw evidence를 남깁니다. run별 JSON과 diagnostics를 그대로 보존해 첫 run의 cold image 차이, timeout, failure를 숨기지 않고 다음 분석 모듈에서 그대로 해석할 수 있게 합니다.

## 예상 소요 시간

25분

## 시작 전 상태

- Module 03을 완료해 `benchmark-path=aks`, `benchmark-path=ondemand`, `benchmark-path=standby` 가 모두 Ready 다.
- Module 02와 Module 03에서 사용한 같은 Cloud Shell 세션을 유지하고 있어 `$RG` 와 `$STANDBY_POOL` 이 아직 살아 있다.
- `~/aci-vn2-performance-workshop` 저장소 루트에서 스크립트를 실행할 수 있다.
- `results/` 아래의 이전 raw evidence를 지우지 않고 새 run을 이어서 보관할 준비가 되었다.

## 진행 순서

1. 현재 shell 세션의 연속성을 확인하고 `results/` 디렉터리를 준비합니다.
2. `aks` 시나리오를 `--runs 3` 으로 실행합니다.
3. `aks` raw 파일과 diagnostics 경로를 확인하고 `jq` 로 per-Pod / batch timing을 빠르게 읽습니다.
4. `vn2-ondemand` 시나리오를 `--runs 3` 으로 실행합니다.
5. `vn2-ondemand` raw 파일과 diagnostics 경로를 확인하고 같은 `jq` 질의를 다시 사용합니다.
6. 첫 run의 node image cache 특성과 run별 JSON을 그대로 유지해야 하는 이유를 확인합니다.

### 1) shell 연속성과 결과 디렉터리 준비

```bash
cd ~/aci-vn2-performance-workshop

set -euo pipefail

: "${RG:?Keep the Module 02 shell session so later diagnostics still point at the same resource group.}"
: "${STANDBY_POOL:?Keep the Module 03 shell session so Module 05 can reuse the same standby pool.}"

mkdir -p results
printf 'RG=%s\nSTANDBY_POOL=%s\n' "$RG" "$STANDBY_POOL"
```

이 모듈의 두 benchmark command는 standby 옵션을 쓰지 않지만, 같은 shell 세션을 유지해야 이후 Module 05에서 `$RG` 와 `$STANDBY_POOL` 을 그대로 재사용할 수 있습니다.

### 2) regular AKS 기준선 3회 실행

```bash
./scripts/run-benchmark.sh \
  --scenario aks \
  --runs 3 \
  --output-dir results
```

이 명령은 `benchmark-path=aks` 라벨이 붙은 일반 AKS VM 노드에서 5개 Pod × 3회를 실행합니다. `run-benchmark.sh` 는 각 run마다 새 namespace를 만들고 raw JSON, diagnostics, namespace cleanup 여부를 자동으로 남깁니다.

### 3) `aks` raw evidence와 diagnostics 확인

```bash
find results/raw -maxdepth 1 -type f -name 'aks-run-*.json' | sort
jq -r '.pods[] | [.name, .terminal_state, .create_to_ready_ms, .node_name] | @tsv' results/raw/aks-run-1.json
jq '{scenario, run, batch: {first_ready_ms: .batch.first_ready_ms, all_ready_ms: .batch.all_ready_ms}}' results/raw/aks-run-1.json
find results/diagnostics -maxdepth 2 -type f -path '*/aks-run-*/*' | sort
```

예상 출력 구조는 다음과 비슷합니다.

```text
results/raw/aks-run-1.json
results/raw/aks-run-2.json
results/raw/aks-run-3.json
bench-aks-run-1-pod-1	ready	1234.0	aks-nodepool1-...
bench-aks-run-1-pod-2	ready	1275.0	aks-nodepool1-...
...
{
  "scenario": "aks",
  "run": 1,
  "batch": {
    "first_ready_ms": 1234.0,
    "all_ready_ms": 1680.0
  }
}
results/diagnostics/aks-run-1/az-container-list.json
results/diagnostics/aks-run-1/kubectl-describe-pods.txt
results/diagnostics/aks-run-1/kubectl-events.txt
results/diagnostics/aks-run-1/kubectl-nodes.json
```

`results/diagnostics/aks-run-1/` 아래의 `kubectl-describe-pods.txt`, `kubectl-events.txt`, `kubectl-nodes.json` 은 timeout/failure가 생겨도 지우지 않습니다. `az-container-list.json` 도 항상 생성되지만, `aks` 와 `vn2-ondemand` run에서는 `--resource-group` 을 전달하지 않았으므로 `skipped --resource-group not provided` 기록이 들어가는 것이 정상입니다.

### 4) `VN2 OnDemand` 3회 실행

```bash
./scripts/run-benchmark.sh \
  --scenario vn2-ondemand \
  --runs 3 \
  --output-dir results
```

이 경로는 standby ready capacity 없이 ACI를 net-new 로 준비하는 흐름을 포함합니다. 따라서 admission controller, ACI provisioning, image pull이 모두 측정값에 반영됩니다.

### 5) `vn2-ondemand` raw evidence와 diagnostics 확인

```bash
find results/raw -maxdepth 1 -type f -name 'vn2-ondemand-run-*.json' | sort
jq -r '.pods[] | [.name, .terminal_state, .create_to_ready_ms, .node_name] | @tsv' results/raw/vn2-ondemand-run-1.json
jq '{scenario, run, batch: {first_ready_ms: .batch.first_ready_ms, all_ready_ms: .batch.all_ready_ms}}' results/raw/vn2-ondemand-run-1.json
find results/diagnostics -maxdepth 2 -type f -path '*/vn2-ondemand-run-*/*' | sort
```

여기서도 raw JSON 하나가 run 하나에 대응합니다. `results/diagnostics/vn2-ondemand-run-1/` 아래에는 `kubectl-describe-pods.txt`, `kubectl-events.txt`, `kubectl-nodes.json`, `az-container-list.json` 이 생성되어 실패 원인과 namespace 정리 상태를 나중에 다시 확인할 수 있습니다.

### 6) 첫 run의 node image cache와 run별 JSON 유지 원칙

regular AKS 노드는 첫 run 에서만 이미지가 cold 상태일 수 있고, 두 번째 이후 run은 같은 VM의 node image cache 덕분에 더 빨라질 수 있습니다. 이 워크숍은 그 차이를 평균값으로 덮지 않기 위해 run별 JSON 을 그대로 보관합니다.

즉, 첫 run 이 느리더라도 outlier처럼 삭제하지 않고 `results/raw/aks-run-1.json` 같은 개별 파일로 남겨 두어야 합니다. 그래야 Module 06에서 “첫 run이 왜 달랐는가”를 batch timing과 per-Pod timing 모두로 설명할 수 있습니다.

## 완료 체크포인트

- `./scripts/run-benchmark.sh --scenario aks --runs 3 --output-dir results` 가 성공했다.
- `./scripts/run-benchmark.sh --scenario vn2-ondemand --runs 3 --output-dir results` 가 성공했다.
- `find results/raw -maxdepth 1 -type f -name 'aks-run-*.json' | sort` 와 `find results/raw -maxdepth 1 -type f -name 'vn2-ondemand-run-*.json' | sort` 에서 6개 raw 파일이 보인다.
- `jq -r '.pods[] | [.name, .terminal_state, .create_to_ready_ms, .node_name] | @tsv' ...` 와 `jq '{scenario, run, batch: {first_ready_ms: .batch.first_ready_ms, all_ready_ms: .batch.all_ready_ms}}' ...` 로 per-Pod / batch timing을 확인했다.
- `results/diagnostics/aks-run-1/` 와 `results/diagnostics/vn2-ondemand-run-1/` 아래의 `kubectl-describe-pods.txt`, `kubectl-events.txt`, `kubectl-nodes.json`, `az-container-list.json` 경로를 확인했다.
- 첫 run의 node image cache 차이 때문에 run별 JSON을 그대로 유지해야 한다는 점을 이해했다.
- 다음 모듈에서 같은 `$RG` 와 `$STANDBY_POOL` 을 그대로 재사용할 준비가 되었다.

## 문제 해결

| 증상 | 원인 후보 | 확인 명령 | 조치 |
| --- | --- | --- | --- |
| `aks` run이 timeout 으로 끝난다 | 일반 AKS 노드에 image pull 지연 또는 다른 워크로드 간섭이 있음 | `jq '{scenario, run, batch, pods: [.pods[] | {name, terminal_state, create_to_ready_ms, node_name}]}' results/raw/aks-run-1.json`, `sed -n '1,160p' results/diagnostics/aks-run-1/kubectl-events.txt`, `sed -n '1,160p' results/diagnostics/aks-run-1/kubectl-describe-pods.txt` | raw JSON과 diagnostics를 보존한 채 원인을 기록하고, node pressure 여부를 확인한 뒤 같은 시나리오를 다시 실행 |
| `vn2-ondemand` run이 `aks` 보다 훨씬 느리다 | 정상적인 net-new ACI provisioning, image pull, admission path가 모두 포함됨 | `jq '{scenario, run, batch}' results/raw/vn2-ondemand-run-1.json`, `sed -n '1,160p' results/diagnostics/vn2-ondemand-run-1/kubectl-events.txt` | 실패가 아니라면 정상 비교값으로 유지하고, Module 06에서 standby 시나리오와 함께 해석 |
| diagnostics 파일이 비어 보인다 | namespace가 빠르게 정리되었거나 `az-container-list.json` 이 skip record일 수 있음 | `find results/diagnostics -maxdepth 2 -type f -path '*/aks-run-*/*' | sort`, `cat results/diagnostics/aks-run-1/az-container-list.json`, `cat results/diagnostics/vn2-ondemand-run-1/az-container-list.json` | 파일이 존재하면 우선 evidence는 확보된 것임. 삭제하지 말고 다음 모듈로 진행 |

## 이전/다음

- 이전: [Module 03](./03-install-dual-vn2.md)
- 다음: [Module 05](./05-standby-cache-benchmark.md)
