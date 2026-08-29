#!/usr/bin/env bash
# Gera os Secrets com os endpoints reais da AWS depois que a infra estiver criada.
# Preencher as variaveis abaixo e rodar. Ele imprime o YAML pronto pra kubectl apply -f -
#
# Por que gerar em vez de editar o YAML na mao: base64 errado nao da erro de sintaxe,
# o pod so sobe e falha na conexao. Ja perdi tempo demais com isso.
set -euo pipefail

# ---- preencher ----
DB_USER="toggle"
DB_PASS=""
RDS_AUTH=""            # ex: togglemaster-auth.abc123.us-east-1.rds.amazonaws.com
RDS_FLAGS=""
RDS_TARGETING=""
ELASTICACHE=""         # ex: togglemaster-redis.abc123.cache.amazonaws.com
SQS_URL=""             # ex: https://sqs.us-east-1.amazonaws.com/123456789012/togglemaster-events
MASTER_KEY=""          # inventar uma, e a senha de admin do auth-service
SERVICE_API_KEY=""     # sai do POST /admin/keys, so existe depois do auth estar no ar
AWS_KEY_ID=""
AWS_SECRET=""
# -------------------

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

for v in DB_PASS RDS_AUTH RDS_FLAGS RDS_TARGETING ELASTICACHE SQS_URL MASTER_KEY AWS_KEY_ID AWS_SECRET; do
  if [ -z "${!v}" ]; then echo "faltou preencher $v" >&2; exit 1; fi
done

cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: auth-secret
  namespace: auth
type: Opaque
data:
  DATABASE_URL: $(b64 "postgres://${DB_USER}:${DB_PASS}@${RDS_AUTH}:5432/auth_db?sslmode=require")
  MASTER_KEY: $(b64 "$MASTER_KEY")
---
apiVersion: v1
kind: Secret
metadata:
  name: flag-secret
  namespace: flags
type: Opaque
data:
  DATABASE_URL: $(b64 "postgres://${DB_USER}:${DB_PASS}@${RDS_FLAGS}:5432/flags_db?sslmode=require")
---
apiVersion: v1
kind: Secret
metadata:
  name: targeting-secret
  namespace: targeting
type: Opaque
data:
  DATABASE_URL: $(b64 "postgres://${DB_USER}:${DB_PASS}@${RDS_TARGETING}:5432/targeting_db?sslmode=require")
---
apiVersion: v1
kind: Secret
metadata:
  name: evaluation-secret
  namespace: evaluation
type: Opaque
data:
  REDIS_URL: $(b64 "redis://${ELASTICACHE}:6379")
  SERVICE_API_KEY: $(b64 "$SERVICE_API_KEY")
  AWS_SQS_URL: $(b64 "$SQS_URL")
  AWS_ACCESS_KEY_ID: $(b64 "$AWS_KEY_ID")
  AWS_SECRET_ACCESS_KEY: $(b64 "$AWS_SECRET")
---
apiVersion: v1
kind: Secret
metadata:
  name: analytics-secret
  namespace: analytics
type: Opaque
data:
  AWS_SQS_URL: $(b64 "$SQS_URL")
  AWS_ACCESS_KEY_ID: $(b64 "$AWS_KEY_ID")
  AWS_SECRET_ACCESS_KEY: $(b64 "$AWS_SECRET")
EOF
