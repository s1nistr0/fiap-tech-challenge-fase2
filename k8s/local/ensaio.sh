#!/usr/bin/env bash
# Ensaio do deploy no Kubernetes local do OrbStack, antes de gastar dinheiro na AWS.
# Aplica os mesmos manifestos da entrega e so troca o que muda de ambiente:
# imagem local no lugar do ECR e endpoint dentro do cluster no lugar do RDS/ElastiCache.
set -euo pipefail
cd "$(dirname "$0")/../.."

INFRA="infra-local.svc.cluster.local"

echo ">> infra local (postgres x2, redis, dynamodb)"
kubectl apply -f k8s/local/00-infra.yaml

echo ">> namespaces e manifestos de entrega"
kubectl apply -f k8s/00-namespaces.yaml
for f in k8s/0[1-5]-*.yaml; do kubectl apply -f "$f"; done

echo ">> secrets apontando pra infra do cluster"
# kubectl create secret ja faz o base64 sozinho, sem risco de eu errar na mao
mk() { kubectl create secret generic "$1" -n "$2" "${@:3}" --dry-run=client -o yaml | kubectl apply -f -; }

mk auth-secret auth \
  --from-literal=DATABASE_URL="postgres://postgres:postgres@postgres-auth.${INFRA}:5432/auth_db?sslmode=disable" \
  --from-literal=MASTER_KEY="admin-secreto-123"

mk flag-secret flags \
  --from-literal=DATABASE_URL="postgres://postgres:postgres@postgres-apps.${INFRA}:5432/flags_db?sslmode=disable"

mk targeting-secret targeting \
  --from-literal=DATABASE_URL="postgres://postgres:postgres@postgres-apps.${INFRA}:5432/targeting_db?sslmode=disable"

mk evaluation-secret evaluation \
  --from-literal=REDIS_URL="redis://redis.${INFRA}:6379" \
  --from-literal=SERVICE_API_KEY="tm_key_local_dev_123" \
  --from-literal=AWS_SQS_URL="" \
  --from-literal=AWS_ACCESS_KEY_ID="local" \
  --from-literal=AWS_SECRET_ACCESS_KEY="local"

# sem SQS local, o worker do analytics fica em retry contra uma porta morta.
# o pod continua saudavel porque o /health nao depende da fila.
mk analytics-secret analytics \
  --from-literal=AWS_SQS_URL="http://127.0.0.1:9324/000000000000/analytics-events" \
  --from-literal=AWS_ACCESS_KEY_ID="local" \
  --from-literal=AWS_SECRET_ACCESS_KEY="local"

kubectl -n analytics patch configmap analytics-config \
  --type merge -p "{\"data\":{\"AWS_DYNAMODB_ENDPOINT\":\"http://dynamodb-local.${INFRA}:8000\"}}"

echo ">> trocando a imagem do ECR pela imagem local"
# imagePullPolicy: Never obriga o kubelet a usar a imagem que ja esta na maquina.
# sem isso ele tenta buscar no registry e da ImagePullBackOff.
for pair in "auth:auth-service" "flags:flag-service" "targeting:targeting-service" \
            "evaluation:evaluation-service" "analytics:analytics-service"; do
  ns="${pair%%:*}"; svc="${pair##*:}"
  kubectl -n "$ns" set image "deploy/$svc" "$svc=togglemaster/$svc:local"
  kubectl -n "$ns" patch "deploy/$svc" --type json \
    -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]' 2>/dev/null \
    || kubectl -n "$ns" patch "deploy/$svc" --type json \
       -p '[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]'
done

echo ">> esperando os pods"
for pair in "auth:auth-service" "flags:flag-service" "targeting:targeting-service" \
            "evaluation:evaluation-service" "analytics:analytics-service"; do
  kubectl -n "${pair%%:*}" rollout status "deploy/${pair##*:}" --timeout=180s || true
done

kubectl get pods -A -l 'app in (auth-service,flag-service,targeting-service,evaluation-service,analytics-service)'
