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

seal() { kubeseal --cert "$CERT" --format yaml > "$OUT/$1"; }
missing=()

# ── postgres-backend-secret + backend-secrets ────────────────────────────────
# **둘을 한 번에 만든다.** 백엔드가 DB 에 붙으려면 같은 비밀번호를 알아야 하는데, 봉인된
# 값은 되읽을 수 없다(그게 봉인의 요점이다). 따로 만들면 두 번째가 첫 번째 값을 알 방법이
# 없어 반드시 어긋난다. 여기서 한 번 만들어 양쪽에 넣는다.
#
# 다시 돌리면 비밀번호가 바뀐다. 이미 배포된 뒤라면 PVC 안의 DB 는 옛 비밀번호를 그대로
# 들고 있으므로, 그때는 이 블록을 돌리지 말고 클러스터의 Secret 을 직접 확인할 것.
ENV_FILE="$FINCH/backend/.env"
if [ -f "$ENV_FILE" ] && grep -q '^KAKAO_CLIENT_ID=' "$ENV_FILE"; then
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
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
  kubectl create secret generic backend-secrets -n "$NS" --dry-run=client -o yaml \
    --from-literal=JWT_SECRET="${JWT_SECRET:-$(openssl rand -hex 48)}" \
    --from-literal=KAKAO_CLIENT_ID="$KAKAO_CLIENT_ID" \
    --from-literal=KAKAO_CLIENT_SECRET="$KAKAO_CLIENT_SECRET" \
    --from-literal=POSTGRES_USER=finch \
    --from-literal=POSTGRES_PASSWORD="$PG_PW" \
    --from-literal=POSTGRES_DB=finch_db \
  | seal sealed-backend-secrets.yaml
  echo "✅ postgres-backend-secret · backend-secrets (같은 비밀번호로)"
else
  missing+=("backend-secrets — $ENV_FILE 에 KAKAO_CLIENT_ID · KAKAO_CLIENT_SECRET")
fi

# ── finch-origin-tls ─────────────────────────────────────────────────────────
# Ingress 가 secretName 으로 직접 참조한다. 없으면 Traefik self-signed 로 떨어지고,
# Cloudflare SSL 이 Full (strict) 이면 526 이 뜬다.
if [ -f "$FINCH/backend/origin.crt" ] && [ -f "$FINCH/backend/origin.key" ]; then
  kubectl create secret tls finch-origin-tls -n "$NS" --dry-run=client -o yaml \
    --cert="$FINCH/backend/origin.crt" --key="$FINCH/backend/origin.key" \
  | seal sealed-origin-tls.yaml
  echo "✅ finch-origin-tls"
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
  echo "✅ ghcr-pull"
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
