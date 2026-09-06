# FINCH GitOps

FINCH ver2 의 **배포 상태**를 코드로 관리하는 저장소입니다.
애플리케이션 소스는 [tpals0409/FINCH](https://github.com/tpals0409/FINCH) 에 있고,
여기에는 Argo CD 애플리케이션, 공용 Helm 차트, 환경별 값, 플랫폼 구성만 둡니다.

CI 는 GitHub Actions, CD 는 Argo CD 입니다.
애플리케이션 저장소의 CI 가 이미지를 GHCR 에 올리면,
그 워크플로가 이 저장소의 `apps/prod/<서비스>/values.yaml` 의 이미지 태그를 갱신하고,
Argo CD 가 그 커밋을 감지해 클러스터에 반영합니다.

## 구조

```
argocd/
  projects/finch.yaml          배포 가능 범위(네임스페이스·저장소) 제한
  root/root-app.yaml           app-of-apps 루트. 이것만 수동 apply 한다
  apps/                        플랫폼 Application (네임스페이스, 데이터)
  applicationsets/             서비스 Application 자동 생성
charts/microservice/           모든 서비스가 공유하는 단일 차트
apps/prod/<서비스>/values.yaml  서비스별 설정. 이것만 쓰면 배포된다
platform/
  namespaces/                  finch-prod
  data/                        postgres 2대, redis
```

### 서비스를 추가하는 법

`apps/prod/` 아래에 디렉터리를 만들고 `values.yaml` 을 넣으면 끝입니다.
ApplicationSet 이 디렉터리를 감지해 Argo CD Application 을 자동으로 만듭니다.
Argo CD YAML 을 직접 쓸 일이 없습니다.

## 서비스 구성

| 서비스 | 포트 | 외부 노출 | 의존 |
|---|---|---|---|
| frontend | 80 | `/` | 없음 |
| backend | 8080 | `/api` | postgres-backend, redis, ai |
| ai | 8000 | 없음 (내부 전용) | postgres-ai |

`ai` 는 Ingress 를 두지 않습니다. compose 의 nginx 에도 ai 로 가는 경로가 없었고
backend 만 클러스터 내부에서 호출합니다.

## 아직 안 된 것

서버가 정해지며 절반이 사라졌다. **k3s·Argo CD·Sealed Secrets·Prometheus Operator 는
이미 서버에 있다**(2026-09-04 실측) — 설치하지 않는다. 남은 것은 아래뿐이다.

1. 🔴 **Argo CD 가 이 저장소를 읽을 방법** — 저장소가 비공개인데 자격증명이 없다.
   루트 앱이 `repository not accessible` 로 즉시 멈춘다. **public 전환을 권한다** —
   SealedSecret 은 공개 저장소에 두라고 만들어진 물건이고 여기에 평문 비밀값은 없다.
   대안은 `repo` 스코프 PAT 를 Argo CD 에 등록하는 것인데, 그 경로는 PAT 평문이
   서버 에이전트를 거친다(봉인으로 못 피한다 — 저장소를 읽어야 봉인본을 가져오는데
   그 읽기 권한을 얻으려는 참이라 순환이다).

2. 🔴 **Secret 세 개** — `backend-secrets` · `finch-origin-tls` (+ 선택 `ghcr-pull`).
   값이 놓이면 `./scripts/seal.sh` 한 번으로 끝난다. 무엇이 왜 필요한지는
   애플리케이션 저장소의 `keys.md` 에 있다.
   `postgres-*-secret` 은 봉인돼 있고, `backend-secrets` 를 만들 때
   `postgres-backend-secret` 도 **같은 비밀번호로 다시 만들어진다** — 따로 만들면
   봉인된 값을 되읽을 수 없어 반드시 어긋난다.

3. **NetworkPolicy** — 차트가 `networking.finch.io/*` 라벨을 붙이는데 받는 정책이 없다.
   **첫 배포 전에 넣지 않기로 했다.** 검증할 클러스터 없이 쓴 정책이 틀리면 배포가
   실패하는데 그 원인이 네트워크라는 걸 알아내기가 가장 어렵다. 한 번 떠서 정상 동작을
   확인한 뒤, 그 상태를 기준으로 조인다. 지금은 단일 테넌트라 얻는 것도 적다.

4. **AI 서비스** — 첫 배포에서 껐다(`apps/prod/ai/values.yaml`). `ai-secrets` 와
   임베딩 10,198청크 복원이 딸려 있어 별개 과제다.

## 이미 된 것

- 호스트 이름 `app.finchapp.org` (frontend `/` · backend `/api`, 같은 호스트라 CORS 없음)
- 이미지 태그 — CI 가 자동 갱신한다
- TLS — Ingress 가 네임스페이스 Secret 을 직접 참조한다. 클러스터의 전역 `TLSStore/default`
  는 삭제됐고 다시 세우지 않는다(전역 기본값이라 나눠 쓸 때 남의 도메인에 우리 인증서가 붙는다)
- 관측 — Prometheus Operator 가 서버에 있어 `metrics` 를 켰다.
  다만 **Grafana·Alertmanager 는 누락 Secret 으로 비정상이다.** 지표는 Prometheus 로 본다

## 애플리케이션 저장소에서 같이 고쳐야 하는 것

**frontend 의 nginx 설정 — 이 항목은 철회한다.** 같은 `infra/nginx/nginx.conf` 를
로컬 compose 의 nginx 서비스도 쓰고 있어서, `proxy_pass` 를 걷어내면 로컬 개발이 깨진다.
쿠버네티스에서는 그 블록이 죽은 설정이지만 해롭지 않다 — Ingress 가 `/api` 를 백엔드로
먼저 채가서 요청이 그 블록에 닿지 않고, upstream 을 변수로 두어 해석이 요청 시점으로
미뤄지므로 nginx 기동도 막지 않는다.

**ai 의 마이그레이션.** 컨테이너 CMD 가 `alembic upgrade head` 를 실행한 뒤 uvicorn 을
띄웁니다. replica 가 1 인 동안은 문제가 없지만, 늘리는 순간 동시 마이그레이션이 됩니다.
그때는 차트의 `bootstrap.enabled` 를 켜서 Job 으로 분리합니다.
