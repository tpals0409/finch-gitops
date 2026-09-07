#!/usr/bin/env bash
# 비밀값을 SealedSecret 으로 봉인해 platform/data/ 에 쓴다.
#
# 클러스터에 접속하지 않는다 — 봉인은 공개키만 있으면 되고 그 공개키는 이 저장소에 있다
# (scripts/sealing-cert.pem). 평문이 서버를 거치지 않는 편이 안전해서 이 방향을 골랐다.
#
# 사용법:
#   FINCH=~/Desktop/FINCH ./scripts/seal.sh
#
# 필요한 것 (없으면 그 항목만 건너뛰고 무엇이 없는지 알려준다):
#   $FINCH/backend/.env        KAKAO_CLIENT_ID · KAKAO_CLIENT_SECRET
#                              (POSTGRES_PASSWORD 는 이 스크립트가 만든다)
#   $FINCH/ai/.env             KIS_APP_KEY · KIS_APP_SECRET · GMS_KEY · DART · KRX · NAVER
#   $FINCH/backend/origin.crt  Cloudflare Origin Certificate
#   $FINCH/backend/origin.key  그 개인키
#   GHCR_PAT (환경변수)         read:packages 스코프. 패키지를 public 으로 돌렸으면 불필요
set -euo pipefail

NS=finch-prod
HERE="$(cd "$(dirname "$0")" && pwd)"
CERT="$HERE/sealing-cert.pem"
OUT="$HERE/../platform/data"
FINCH="${FINCH:-$HOME/Desktop/FINCH}"

command -v kubeseal >/dev/null || { echo "kubeseal 이 없다: brew install kubeseal"; exit 1; }
[ -f "$CERT" ] || { echo "봉인 공개키가 없다: $CERT"; exit 1; }

# 이미 있는 봉인본은 **덮어쓰지 않는다.** postgres 비밀번호는 PVC 안의 DB 가 함께 들고 있어서,
# 다시 만들면 새 Secret 으로는 붙지 못한다 — 고치려면 PVC 를 지워야 하고 그건 데이터를 버리는
# 일이다. 실제로 이 스크립트를 배포 후에 다시 돌려 그 사고가 날 뻔했다.
#
# 의도적으로 다시 만들려면 FORCE=1 을 준다. 그때는 해당 PVC 도 같이 지워야 한다.
# 이 함수는 파이프 오른쪽에서 돌아 **서브셸**이다. 바깥 배열에 쌓아도 부모에 안 남으므로
# 건너뛴 사실을 여기서 바로 찍는다 (실측으로 확인한 함정이다).
seal() {
  if [ -f "$OUT/$1" ] && [ "${FORCE:-}" != "1" ]; then
    cat > /dev/null                      # 파이프를 비워 SIGPIPE 를 막는다
    echo "⏭  $1 — 이미 있어 그대로 둔다 (FORCE=1 로 강제. PVC 도 같이 지워야 한다)"
    return
  fi
  kubeseal --cert "$CERT" --format yaml > "$OUT/$1"
  echo "✅ $1"
}
missing=()

# ── finch-service-token ──────────────────────────────────────────────────────
# 백엔드와 AI 가 **같은 값**을 가져야 하는 내부 토큰. AI 는 prod 에서 이 값이 없으면
# 모든 요청을 internal_token_not_configured 로 거절한다 (ai/app/api/deps.py).
#
# **자기 Secret 을 따로 쓴다.** 처음엔 backend-secrets · ai-secrets 양쪽에 같은 값을 넣었는데,
# 두 봉인본은 각자 DB 비밀번호를 품고 있어 한쪽만 다시 만들 수가 없다 — 토큰을 맞추려면
# 멀쩡한 원장 DB 의 비밀번호까지 갈아엎어야 했다. 공유하는 값은 공유하는 자리에 둔다.
#
# ai-secrets 안에는 옛 BACKEND_SERVICE_TOKEN 이 아직 남아 있다. 두 values.yaml 이 이 값을
# envFrom 이 아니라 env + secretKeyRef 로 읽으므로 그쪽이 확정적으로 이긴다 (env > envFrom).
kubectl create secret generic finch-service-token -n "$NS" --dry-run=client -o yaml \
  --from-literal=BACKEND_SERVICE_TOKEN="$(openssl rand -hex 32)" \
| seal sealed-service-token.yaml

# ── postgres-backend-secret + backend-secrets ────────────────────────────────
# **둘을 한 번에 만든다.** 백엔드가 DB 에 붙으려면 같은 비밀번호를 알아야 하는데, 봉인된
# 값은 되읽을 수 없다(그게 봉인의 요점이다). 따로 만들면 두 번째가 첫 번째 값을 알 방법이
# 없어 반드시 어긋난다. 여기서 한 번 만들어 양쪽에 넣는다.
#
# 다시 돌리면 비밀번호가 바뀐다. 이미 배포된 뒤라면 PVC 안의 DB 는 옛 비밀번호를 그대로
# 들고 있으므로, 그때는 이 블록을 돌리지 말고 클러스터의 Secret 을 직접 확인할 것.
ENV_FILE="$FINCH/backend/.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
fi
# **값이 비었는지까지 본다.** 파일에 이름만 적어두고 값을 안 채운 상태가 제일 흔한데,
# 존재만 확인하면 빈 문자열이 그대로 봉인된다. 그러면 파드는 정상 기동하고 로그인만
# 죽는다 — 조용히 실패하는 종류다. 여기서 막는 편이 배포 후에 찾는 것보다 싸다.
if [ -n "${KAKAO_CLIENT_ID:-}" ] && [ -n "${KAKAO_CLIENT_SECRET:-}" ]; then
  # openssl rand 를 쓴다. `tr </dev/urandom | head -c` 는 head 가 파이프를 닫는 순간
  # tr 이 SIGPIPE 로 죽고 pipefail 이 그것을 스크립트 실패로 본다 (실측: exit 141).
  PG_PW="$(openssl rand -hex 20)"

  kubectl create secret generic postgres-backend-secret -n "$NS" --dry-run=client -o yaml \
    --from-literal=POSTGRES_USER=finch \
    --from-literal=POSTGRES_PASSWORD="$PG_PW" \
    --from-literal=POSTGRES_DB=finch_db \
  | seal sealed-postgres-backend.yaml

  # 이름은 application.yaml 이 읽는 그대로다. 하나라도 빠지면 파드가 기동에 실패한다 —
  # 비밀값에 기본값을 두지 않기로 한 규칙의 대가이자 목적이다(조용히 틀린 값으로 붙지 않는다).
  # KIS 키는 ai/.env 에 있다. 발급만 받고 아직 아무도 쓰지 않던 값인데, 배포 후 서버에서
  # 토큰을 발급해 **IP 화이트리스트 요구 여부를 판명하는 것**이 이번 배포의 목적이라
  # 파드 안에 있어야 한다. 없으면 그 확인 자체를 할 수단이 없다.
  KIS_ARGS=()
  if [ -f "$FINCH/ai/.env" ]; then
    KIS_APP_KEY=$(grep '^KIS_APP_KEY=' "$FINCH/ai/.env" | cut -d= -f2-)
    KIS_APP_SECRET=$(grep '^KIS_APP_SECRET=' "$FINCH/ai/.env" | cut -d= -f2-)
    if [ -n "$KIS_APP_KEY" ] && [ -n "$KIS_APP_SECRET" ]; then
      KIS_ARGS=(--from-literal=KIS_APP_KEY="$KIS_APP_KEY"
                --from-literal=KIS_APP_SECRET="$KIS_APP_SECRET")
    fi
  fi

  kubectl create secret generic backend-secrets -n "$NS" --dry-run=client -o yaml \
    --from-literal=JWT_SECRET="${JWT_SECRET:-$(openssl rand -hex 48)}" \
    --from-literal=KAKAO_CLIENT_ID="$KAKAO_CLIENT_ID" \
    --from-literal=KAKAO_CLIENT_SECRET="$KAKAO_CLIENT_SECRET" \
    --from-literal=POSTGRES_USER=finch \
    --from-literal=POSTGRES_PASSWORD="$PG_PW" \
    --from-literal=POSTGRES_DB=finch_db \
    "${KIS_ARGS[@]}" \
  | seal sealed-backend-secrets.yaml
  # 무엇이 새로 만들어졌는지는 위의 파일별 ✅ / ⏭ 가 말한다.
else
  missing+=("backend-secrets — $ENV_FILE 의 KAKAO_CLIENT_ID · KAKAO_CLIENT_SECRET (이름만 있고 값이 비어도 건너뛴다)")
fi

# ── postgres-ai-secret + ai-secrets ──────────────────────────────────────────
# **둘을 한 번에 만든다.** AI 의 DATABASE_URL 이 postgres-ai 비밀번호를 품는데 봉인된 값은
# 되읽을 수 없다 — 백엔드 쪽과 똑같은 이유다.
#
# ⚠️ **postgres-ai 가 이미 떠 있었다면 PVC 를 지워야 한다.** PVC 안의 DB 는 옛 비밀번호를
# 그대로 들고 있어 새 Secret 으로는 붙지 못한다. 그 DB 는 코퍼스 복원 전이라 비어 있다.
AI_ENV="$FINCH/ai/.env"
if [ -f "$AI_ENV" ]; then
  GMS_KEY=$(grep '^GMS_KEY=' "$AI_ENV" | cut -d= -f2-)
  DART_API_KEY=$(grep '^DART_API_KEY=' "$AI_ENV" | cut -d= -f2-)
  KRX_API_KEY=$(grep '^KRX_API_KEY=' "$AI_ENV" | cut -d= -f2-)
  NAVER_CLIENT_ID=$(grep '^NAVER_CLIENT_ID=' "$AI_ENV" | cut -d= -f2-)
  NAVER_CLIENT_SECRET=$(grep '^NAVER_CLIENT_SECRET=' "$AI_ENV" | cut -d= -f2-)
fi

if [ -n "${GMS_KEY:-}" ]; then
  PG_AI_PW="$(openssl rand -hex 20)"

  kubectl create secret generic postgres-ai-secret -n "$NS" --dry-run=client -o yaml \
    --from-literal=POSTGRES_USER=ai_invest \
    --from-literal=POSTGRES_PASSWORD="$PG_AI_PW" \
    --from-literal=POSTGRES_DB=ai_invest \
  | seal sealed-postgres-ai.yaml

  # DATABASE_URL 은 클러스터 주소다. 로컬 .env 의 localhost 를 그대로 쓰면 파드가 자기
  # 안을 찾는다. asyncpg 드라이버 표기도 앱이 기대하는 그대로여야 한다 (ai/app/core/config.py).
  kubectl create secret generic ai-secrets -n "$NS" --dry-run=client -o yaml \
    --from-literal=DATABASE_URL="postgresql+asyncpg://ai_invest:${PG_AI_PW}@postgres-ai:5432/ai_invest" \
    --from-literal=GMS_KEY="$GMS_KEY" \
    --from-literal=DART_API_KEY="${DART_API_KEY:-}" \
    --from-literal=KRX_API_KEY="${KRX_API_KEY:-}" \
    --from-literal=NAVER_CLIENT_ID="${NAVER_CLIENT_ID:-}" \
    --from-literal=NAVER_CLIENT_SECRET="${NAVER_CLIENT_SECRET:-}" \
  | seal sealed-ai-secrets.yaml
else
  missing+=("ai-secrets — $AI_ENV 의 GMS_KEY")
fi

# ── finch-origin-tls ─────────────────────────────────────────────────────────
# Ingress 가 secretName 으로 직접 참조한다. 없으면 Traefik self-signed 로 떨어지고,
# Cloudflare SSL 이 Full (strict) 이면 526 이 뜬다.
if [ -s "$FINCH/backend/origin.crt" ] && [ -s "$FINCH/backend/origin.key" ]; then
  kubectl create secret tls finch-origin-tls -n "$NS" --dry-run=client -o yaml \
    --cert="$FINCH/backend/origin.crt" --key="$FINCH/backend/origin.key" \
  | seal sealed-origin-tls.yaml
else
  missing+=("finch-origin-tls — $FINCH/backend/origin.crt · origin.key")
fi

# ── ghcr-pull ────────────────────────────────────────────────────────────────
# GHCR 패키지를 public 으로 돌렸으면 아예 필요 없다. 그 편이 PAT 만료로 새벽에
# ImagePullBackOff 를 보는 실패 모드를 통째로 없앤다.
if [ -n "${GHCR_PAT:-}" ]; then
  kubectl create secret docker-registry ghcr-pull -n "$NS" --dry-run=client -o yaml \
    --docker-server=ghcr.io --docker-username=tpals0409 --docker-password="$GHCR_PAT" \
  | seal sealed-ghcr-pull.yaml
else
  missing+=("ghcr-pull — GHCR_PAT 환경변수 (패키지가 public 이면 건너뛴다)")
fi

if [ ${#missing[@]} -gt 0 ]; then
  echo
  echo "건너뛴 것:"
  printf '  · %s\n' "${missing[@]}"
  echo
  echo "자세한 것은 keys.md 를 본다."
fi
