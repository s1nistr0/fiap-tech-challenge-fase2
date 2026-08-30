# Manifestos do Kubernetes

Um arquivo por serviço. Cada um traz tudo daquele serviço junto - ConfigMap, Secret,
Deployment, Service, Ingress e o HPA quando tem - separados por `---`. Preferi assim em vez
de espalhar em 30 arquivinhos: quando eu quiser entender o evaluation-service inteiro, é um
arquivo só.

```
00-namespaces.yaml   os 5 namespaces
01-auth.yaml         auth-service
02-flags.yaml        flag-service
03-targeting.yaml    targeting-service
04-evaluation.yaml   evaluation-service + HPA
05-analytics.yaml    analytics-service + HPA
gerar-secrets.sh     gera os Secrets com os endpoints reais
```

## O que precisa ser trocado antes de aplicar

Os manifestos estão commitados com placeholder. Procure por `TROCAR`:

- `TROCAR_ACCOUNT_ID` na imagem de cada Deployment (o ID da conta AWS no endereço do ECR)
- os Secrets inteiros - não edite o base64 na mão, use o `gerar-secrets.sh`

## Ordem de aplicação

**Os manifestos vêm primeiro, os Secrets reais depois.** Cada arquivo de serviço contém um
Secret com placeholder, então aplicar o manifesto por cima de um Secret já preenchido
sobrescreve ele de volta pro placeholder. O pod sobe, tenta conectar em
`TROCAR-ENDPOINT-RDS-AUTH` e entra em CrashLoopBackOff. Perdi tempo com isso, aplicando na
ordem errada.

```bash
# 1. namespaces primeiro, senao nada tem onde nascer
kubectl apply -f k8s/00-namespaces.yaml

# 2. metrics server, senao o HPA fica com <unknown> e nao escala nada
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl top nodes   # se der erro de TLS, ver a secao de problemas conhecidos

# 3. nginx ingress controller (cria o Load Balancer na AWS)
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace

# 4. os secrets com os valores reais
./k8s/gerar-secrets.sh | kubectl apply -f -

# 5. as aplicacoes. o auth vem primeiro porque flag e targeting dependem dele
kubectl apply -f k8s/01-auth.yaml
kubectl apply -f k8s/02-flags.yaml
kubectl apply -f k8s/03-targeting.yaml
kubectl apply -f k8s/04-evaluation.yaml
kubectl apply -f k8s/05-analytics.yaml
```

Atenção no passo 4: o `SERVICE_API_KEY` do evaluation só existe depois que o auth-service
estiver no ar, porque ela é gerada por uma chamada HTTP nele. A sequência real é: sobe o
auth, cria a chave, regera o secret do evaluation, sobe o evaluation.

```bash
# depois do auth-service estar Running:
kubectl -n auth port-forward svc/auth-service 8001:8001 &
curl -X POST http://localhost:8001/admin/keys \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H 'Content-Type: application/json' -d '{"name":"evaluation-service"}'
# copiar o campo "key" da resposta pro SERVICE_API_KEY do gerar-secrets.sh
```

## Conferindo

```bash
kubectl get pods -A                  # os 5 Running
kubectl get svc -A                   # os ClusterIP
kubectl get ingress -A               # os 5 ingress, todos com o mesmo endereco de LB
kubectl get hpa -A                   # os 2 HPAs, com TARGETS mostrando percentual e nao <unknown>

# endereco publico
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

## As rotas do Ingress

| Caminho | Vai para | Rewrite |
|---|---|---|
| `/auth/...` | auth-service:8001 | sim, remove o `/auth` |
| `/flags` | flag-service:8002 | não, a rota da app já é `/flags` |
| `/rules` | targeting-service:8003 | não, a rota da app já é `/rules` |
| `/evaluate` | evaluation-service:8004 | não |
| `/analytics/...` | analytics-service:8005 | sim, remove o `/analytics` |

São **5 objetos Ingress, um em cada namespace**, e não um só. Isso não foi escolha: um
Ingress só consegue apontar pra Service do próprio namespace. Como o desafio pede um
namespace por serviço, o roteamento tem que ser distribuído. Todos declaram
`ingressClassName: nginx`, então o mesmo controller lê os cinco e monta uma tabela de rotas
única atrás de um único Load Balancer.

## Demonstrando o autoscaling

```bash
LB=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# terminal 1: assiste o HPA
kubectl get hpa -n evaluation -w

# terminal 2: carga
hey -z 3m -c 50 "http://$LB/evaluate?user_id=carga&flag_name=enable-new-dashboard"
```

Pro analytics, a carga é encher a fila:

```bash
for i in $(seq 1 500); do
  aws sqs send-message --queue-url "$SQS_URL" \
    --message-body "{\"user_id\":\"u$i\",\"flag_name\":\"enable-new-dashboard\",\"result\":true,\"timestamp\":\"2026-01-01T00:00:00Z\"}" &
done; wait
```

## Problemas conhecidos

**`kubectl top nodes` dá erro de certificado.** O Metrics Server tenta falar com o kubelet
por TLS e o certificado do nó não bate com o nome. Solução:

```bash
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

**HPA com `TARGETS: <unknown>`.** Ou o Metrics Server não está pronto, ou o Deployment está
sem `resources.requests.cpu`. O HPA calcula percentual em cima do request - sem request,
não tem como calcular.

**Pod em `ImagePullBackOff`.** Duas causas comuns: o `TROCAR_ACCOUNT_ID` ficou no
manifesto, ou a imagem foi buildada em Mac ARM sem `--platform linux/amd64` e o nó x86 não
consegue executar.

**Pod em `CrashLoopBackOff` logo na subida.** Quase sempre é o Secret: as três aplicações
com banco fazem `sys.exit(1)` / `log.Fatal` se não conseguirem conectar. `kubectl logs` do
pod mostra a mensagem exata.
