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

이 저장소는 뼈대까지만 있습니다. 서버가 정해져야 채울 수 있는 것들이 남았습니다.

1. **서버 부트스트랩** — k3s 설치, Sealed Secrets, Argo CD 설치, 루트 앱 apply.
   서버 사양과 접근 방법이 정해지면 `bootstrap/` 에 스크립트를 넣습니다.
2. **Secret** — `backend-secrets`, `ai-secrets`, `postgres-*-secret`, `ghcr-pull`.
   SealedSecret 은 클러스터의 봉인 키로 암호화하므로 클러스터를 만든 뒤에 생성합니다.
3. **호스트 이름** — values 의 `CHANGEME.example.com` 자리. 도메인이 정해지면 채웁니다.
4. **이미지 태그** — values 의 `CHANGEME`. 첫 이미지를 빌드한 뒤 채웁니다.
5. **관측 스택** — Prometheus, Loki, Grafana. compose 쪽 구성이 이미 있으니 옮겨옵니다.
6. **NetworkPolicy** — 차트가 `networking.finch.io/ingress`, `/metrics` 라벨을
   자동으로 붙입니다. 그 라벨을 받는 정책을 아직 안 썼습니다.

## 애플리케이션 저장소에서 같이 고쳐야 하는 것

**frontend 의 nginx 설정.** 지금 `infra/nginx/nginx.conf` 는 `/api/` 를 backend 로
프록시합니다. 쿠버네티스에서는 Ingress 가 그 일을 하므로, frontend 이미지의 nginx 는
정적 파일만 서빙하면 됩니다. proxy_pass 블록과 Jenkins 관련 location 을 걷어내야 합니다.

**ai 의 마이그레이션.** 컨테이너 CMD 가 `alembic upgrade head` 를 실행한 뒤 uvicorn 을
띄웁니다. replica 가 1 인 동안은 문제가 없지만, 늘리는 순간 동시 마이그레이션이 됩니다.
그때는 차트의 `bootstrap.enabled` 를 켜서 Job 으로 분리합니다.
