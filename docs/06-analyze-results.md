# Module 06. 결과 분석과 해석

## 목표

네 시나리오에서 수집한 raw JSON을 summary JSON, CSV, Markdown으로 정리하고 median, p95, min/max, speed-up, failure count를 근거로 결과를 해석합니다.

## 예상 소요 시간

20분

## 시작 전 상태

- Module 04와 Module 05에서 네 시나리오의 raw JSON이 모두 생성되었다.
- `results/raw` 아래 파일 이름이 시나리오/런 번호 규칙을 따른다.
- 실패 또는 timeout sample을 삭제하지 않았다.

## 진행 순서

1. raw 파일 수와 시나리오 분포를 빠르게 점검합니다.
2. summary 스크립트를 실행해 JSON, CSV, Markdown 산출물을 동시에 생성합니다.
3. `vn2-ondemand` 를 기준으로 standby 시나리오 speed-up ratio를 확인합니다.
4. p95가 15개 Pod sample 기반의 기술 통계라는 점을 명시합니다.
5. outlier, timeout, standby fallback 가능성을 summary와 raw evidence를 함께 읽으며 해석합니다.

```bash
cd ~/aci-vn2-performance-workshop
find results/raw -maxdepth 1 -type f | sort
python3 scripts/summarize-results.py --input results/raw --output-dir results
sed -n '1,200p' results/summary.md
python3 -m json.tool results/summary.json | sed -n '1,120p'
```

해석 시 주의할 점은 “가장 빠른 한 번”이 아니라 반복된 15개 Pod sample의 분포를 보는 것입니다. p95는 샘플 수가 작기 때문에 SLA 근거가 아니라 descriptive metric으로 다뤄야 하며, timeout과 failure count는 성공 샘플 통계와 따로 분리해 읽어야 합니다.

## 완료 체크포인트

- `results/summary.json`, `results/summary.csv`, `results/summary.md` 가 모두 생성되었다.
- `vn2-ondemand` 대비 standby 시나리오의 speed-up ratio를 확인했다.
- p95 해석 한계를 팀에 설명할 수 있다.
- outlier, timeout, fallback evidence를 삭제하지 않고 유지했다.
- cleanup 전에 보관할 산출물 위치를 정리했다.

## 이전/다음

- 이전: [Module 05](./05-standby-cache-benchmark.md)
- 다음: [Module 07](./07-limitations-troubleshooting-cleanup.md)
