#!/usr/bin/env bash
# Gera os Secrets do Kubernetes com os endpoints reais.
#
# Os endpoints ele busca sozinho na AWS - digitar endpoint na mao e pedir pra errar,
# e endpoint errado nao da erro de sintaxe, o pod so sobe e falha na conexao.
#
# As senhas vem de .aws-app-creds.env na raiz do projeto (fora do git):
#   APP_AWS_ACCESS_KEY_ID       chave do usuario IAM togglemaster-app
#   APP_AWS_SECRET_ACCESS_KEY
#   RDS_PASSWORD                senha do usuario toggle nos 3 RDS
#   MASTER_KEY                  senha de admin do auth-service
#   SERVICE_API_KEY             so existe depois do auth-service estar no ar
#
# Uso: ./k8s/gerar-secrets.sh | kubectl apply -f -
set -euo pipefail
cd "$(dirname "$0")/.."

CREDS=.aws-app-creds.env
[ -f "$CREDS" ] || { echo "faltou o $CREDS" >&2; exit 1; }
set -a; . "./$CREDS"; set +a

for v in APP_AWS_ACCESS_KEY_ID APP_AWS_SECRET_ACCESS_KEY RDS_PASSWORD; do
  [ -n "${!v:-}" ] || { echo "faltou $v no $CREDS" >&2; exit 1; }
done

: "${MASTER_KEY:=}"
: "${SERVICE_API_KEY:=}"
DB_USER=toggle

rds() { aws rds describe-db-instances --db-instance-identifier "$1" \
          --query 'DBInstances[0].Endpoint.Address' --output text; }

RDS_AUTH=$(rds togglemaster-auth)
RDS_FLAGS=$(rds togglemaster-flags)
RDS_TARGETING=$(rds togglemaster-targeting)

REDIS=$(aws elasticache describe-replication-groups --replication-group-id togglemaster-redis \
          --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address' --output text)
# o cluster subiu com criptografia em transito exigida, entao e rediss:// e nao redis://.
# o go-redis liga o TLS sozinho quando ve esse esquema na URL.
TLS=$(aws elasticache describe-replication-groups --replication-group-id togglemaster-redis \
        --query 'ReplicationGroups[0].TransitEncryptionEnabled' --output text)
[ "$TLS" = "True" ] && SCHEME=rediss || SCHEME=redis

SQS_URL=$(aws sqs get-queue-url --queue-name togglemaster-events --query QueueUrl --output text)

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# senha vai dentro de uma URL, entao precisa de percent-encoding.
# aprendi na marra: senha com # cortava a string no parser do pgx e o auth nao subia.
urlenc() { printf '%s' "$1" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""), end="")'; }
PW=$(urlenc "$RDS_PASSWORD")

cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: auth-secret
  namespace: auth
type: Opaque
data:
  DATABASE_URL: $(b64 "postgres://${DB_USER}:${PW}@${RDS_AUTH}:5432/auth_db?sslmode=require")
  MASTER_KEY: $(b64 "$MASTER_KEY")
---
apiVersion: v1
kind: Secret
metadata:
  name: flag-secret
  namespace: flags
type: Opaque
data:
  DATABASE_URL: $(b64 "postgres://${DB_USER}:${PW}@${RDS_FLAGS}:5432/flags_db?sslmode=require")
---
apiVersion: v1
kind: Secret
metadata:
  name: targeting-secret
  namespace: targeting
type: Opaque
data:
  DATABASE_URL: $(b64 "postgres://${DB_USER}:${PW}@${RDS_TARGETING}:5432/targeting_db?sslmode=require")
---
apiVersion: v1
kind: Secret
metadata:
  name: evaluation-secret
  namespace: evaluation
type: Opaque
data:
  REDIS_URL: $(b64 "${SCHEME}://${REDIS}:6379")
  SERVICE_API_KEY: $(b64 "$SERVICE_API_KEY")
  AWS_SQS_URL: $(b64 "$SQS_URL")
  AWS_ACCESS_KEY_ID: $(b64 "$APP_AWS_ACCESS_KEY_ID")
  AWS_SECRET_ACCESS_KEY: $(b64 "$APP_AWS_SECRET_ACCESS_KEY")
---
apiVersion: v1
kind: Secret
metadata:
  name: analytics-secret
  namespace: analytics
type: Opaque
data:
  AWS_SQS_URL: $(b64 "$SQS_URL")
  AWS_ACCESS_KEY_ID: $(b64 "$APP_AWS_ACCESS_KEY_ID")
  AWS_SECRET_ACCESS_KEY: $(b64 "$APP_AWS_SECRET_ACCESS_KEY")
EOF
