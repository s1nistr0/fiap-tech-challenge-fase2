# ToggleMaster - Tech Challenge Fase 2

Guilherme da Silva Vicenti - RM375040 - POSTECH DevOps e Arquitetura Cloud

Na Fase 1 o ToggleMaster era um monolito. Nesta fase ele foi quebrado em 5 microsserviços,
e o meu trabalho aqui foi pegar esse código, conteinerizar, provisionar a infraestrutura na
AWS e colocar tudo pra rodar em Kubernetes com escalabilidade automática.

Este README é a versão escrita do que eu explico no vídeo.

## O que é o ToggleMaster, em uma frase

É um sistema de **feature flags**: um jeito de ligar e desligar funcionalidades de um
produto sem precisar fazer deploy. Você marca uma feature como "ligada pra 50% dos
usuários", e o sistema responde true ou false pra cada usuário que perguntar.

## Os 5 serviços e o que cada um faz

**auth-service** (Go) - o porteiro. Ele guarda chaves de API e responde uma pergunta só:
"essa chave é válida?". Nunca guarda a chave em texto plano, só o hash SHA-256 dela. Os
outros serviços perguntam pra ele antes de deixar qualquer requisição passar.

**flag-service** (Python) - o cadastro. É o CRUD das flags: nome, descrição e o interruptor
geral (`is_enabled`). Se a flag está desligada aqui, está desligada pra todo mundo, não
importa mais nada.

**targeting-service** (Python) - as regras de quem recebe o quê. Guarda coisas do tipo
"essa flag vale pra 50% dos usuários". A regra fica num campo JSONB do PostgreSQL, o que
me deixa mudar o formato da regra depois sem migração de schema.

**evaluation-service** (Go) - o que responde de verdade. É o *caminho quente*: recebe
`user_id` + `flag_name` e devolve true ou false. Pra não bater no banco a cada chamada, ele
junta os dados do flag-service e do targeting-service uma vez e guarda no Redis por 30
segundos. A decisão em si é determinística: ele faz um hash do `user_id + flag_name`, tira
o módulo 100 e compara com a porcentagem. Ou seja, o mesmo usuário sempre recebe a mesma
resposta - o que importa, porque ninguém quer ver um botão aparecer e sumir a cada refresh.

**analytics-service** (Python) - o histórico. Não fica no caminho da requisição: ele
consome eventos de uma fila SQS e grava no DynamoDB. Se ele cair, ninguém percebe na hora,
as mensagens ficam esperando na fila.

## Como eles conversam

```mermaid
flowchart TB
    user([Cliente]) --> ing[Nginx Ingress<br/>Load Balancer da AWS]

    ing -->|/auth| auth[auth-service<br/>Go :8001]
    ing -->|/flags| flag[flag-service<br/>Python :8002]
    ing -->|/rules| targ[targeting-service<br/>Python :8003]
    ing -->|/evaluate| eval[evaluation-service<br/>Go :8004]
    ing -->|/analytics| ana[analytics-service<br/>Python :8005]

    flag -.->|essa chave vale?| auth
    targ -.->|essa chave vale?| auth
    eval -->|so no cache miss| flag
    eval -->|so no cache miss| targ

    auth --> rds1[(RDS PostgreSQL<br/>auth_db)]
    flag --> rds2[(RDS PostgreSQL<br/>flags_db)]
    targ --> rds3[(RDS PostgreSQL<br/>targeting_db)]
    eval --> redis[(ElastiCache Redis<br/>cache de 30s)]

    eval -->|evento, sem esperar resposta| sqs[[SQS Standard]]
    sqs -->|consome em lote| ana
    ana --> dynamo[(DynamoDB<br/>ToggleMasterAnalytics)]

    hpa1{{HPA - CPU 70%}} -.-> eval
    hpa2{{HPA - CPU 70%}} -.-> ana
```

A parte que eu acho mais bonita da arquitetura é a seta pontilhada do evaluation pro SQS.
Ela é assíncrona: o serviço responde pro cliente e *só depois* manda o evento pra fila,
numa goroutine. Se o SQS estiver lento ou fora do ar, o usuário nem fica sabendo. Isso é
o que permite os dois lados escalarem separado - o evaluation escala por tráfego HTTP, o
analytics escala por tamanho de fila.

## Por que três bancos diferentes

Essa é a pergunta que o desafio pede pra responder, e a resposta curta é: eles resolvem
problemas diferentes.

| | Para quê | Por que não os outros |
|---|---|---|
| **RDS PostgreSQL** | dados que precisam de consistência e relacionamento: cadastro de flags, chaves, regras | precisa de UNIQUE, transação e query com JOIN. Nem Redis nem DynamoDB fazem isso bem |
| **ElastiCache Redis** | cache de leitura com TTL de 30s no caminho quente | é dado descartável. Se o Redis perder tudo, o serviço relê da origem e segue. Guardar isso no RDS seria pagar latência à toa |
| **DynamoDB** | eventos de analytics: escrita em volume, append-only, sempre buscados por chave | esse volume derrubaria o db.t3.micro do RDS. O DynamoDB escala escrita sem eu gerenciar nó nenhum, e eu nunca preciso de JOIN aqui |

Resumindo do jeito que eu penso: RDS é **verdade**, Redis é **velocidade**, DynamoDB é
**volume**.

## Rodando na sua máquina

Só precisa de Docker. Nada de Go, nada de Python instalado.

```bash
docker compose up -d --build
docker compose ps
```

Sobem 9 containers: os 5 serviços, 2 PostgreSQL, 1 Redis e 1 DynamoDB Local.

<details>
<summary><b>Teste completo com curl (clique pra abrir)</b></summary>

```bash
K="tm_key_local_dev_123"

# 1. os 5 respondem?
for p in 8001 8002 8003 8004 8005; do curl -s http://localhost:$p/health; echo; done

# 2. cria uma feature flag, ligada
curl -X POST http://localhost:8002/flags \
  -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
  -d '{"name":"enable-new-dashboard","description":"demo","is_enabled":true}'

# 3. define que ela vale pra 50% dos usuarios
curl -X POST http://localhost:8003/rules \
  -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
  -d '{"flag_name":"enable-new-dashboard","rules":{"type":"PERCENTAGE","value":50}}'

# 4. pergunta pro evaluation. repita o mesmo user_id: a resposta nunca muda
curl "http://localhost:8004/evaluate?user_id=user-1&flag_name=enable-new-dashboard"
curl "http://localhost:8004/evaluate?user_id=user-abc&flag_name=enable-new-dashboard"

# 5. sem a chave, tem que dar 401
curl -i http://localhost:8002/flags
```

Pra ver o cache trabalhando:

```bash
docker compose logs evaluation-service | grep Cache
```

A primeira chamada é `Cache MISS` e vai buscar no flag-service e no targeting-service em
paralelo (duas goroutines). As próximas 30 segundos são `Cache HIT` e nem tocam no banco.

</details>

<details>
<summary><b>Detalhes chatos mas importantes do ambiente local</b></summary>

**A chave de API já vem cadastrada.** O `evaluation-service` precisa de uma chave válida
pra falar com os outros dois, mas essa chave só existe depois que alguém chama
`POST /admin/keys` no auth-service. Como isso é um ovo-e-galinha chato de repetir toda vez,
eu pré-cadastrei o hash SHA-256 de uma chave de desenvolvimento direto no init do
PostgreSQL (`local/postgres-auth/02-dev-key.sql`). A chave em texto plano é
`tm_key_local_dev_123` e ela **só existe localmente** - na AWS a chave é gerada de verdade.

**São 2 PostgreSQL locais, mas 3 RDS na nuvem.** O desafio pede exatamente isso. Local, o
container `postgres-apps` hospeda o `flags_db` e o `targeting_db` juntos. Na AWS cada
serviço ganha a própria instância, que é o certo pra microsserviço: cada um dono do seu
banco.

**Não tem fila local.** O desafio pede 4 bancos locais e nenhuma fila. Então o
`evaluation-service` detecta que não recebeu `AWS_SQS_URL`, loga `[SQS_DISABLED]` e segue
funcionando normal. O fluxo com fila de verdade acontece no EKS.

</details>

## Deploy na AWS

Os manifestos estão em `k8s/`, um arquivo por serviço. Cada arquivo tem tudo do serviço
junto: Namespace, ConfigMap, Secret, Deployment, Service e Ingress. Ver `k8s/README.md`
pra ordem de aplicação e o que precisa ser preenchido.

O que eu provisiono:

- **EKS** `togglemaster` via eksctl, node group de 2x t3.medium (min 1, desejado 2, max 4)
- **ECR** com 5 repositórios, um por serviço
- **RDS** 3x PostgreSQL db.t3.micro, sem acesso público
- **ElastiCache** 1 nó Redis cache.t3.micro
- **DynamoDB** tabela `ToggleMasterAnalytics`, partition key `event_id` (String)
- **SQS** 1 fila Standard

Tudo com a tag `projeto=techchallenge-fase2`, pra eu conseguir achar e destruir tudo depois
sem esquecer nada cobrando.

Instâncias propositalmente pequenas: isso é ambiente de demonstração, criado e destruído no
mesmo dia. Em produção nada disso seria single-AZ nem db.t3.micro.

## Escalabilidade

HPA por CPU nos dois serviços que sofrem carga variável.

**evaluation-service** é o caso óbvio: mais requisição HTTP, mais CPU, mais réplica.

**analytics-service** é o caso interessante. Ele é um worker de fila, e o sinal natural pra
escalar ele seria o tamanho da fila, não a CPU. Mas funciona por CPU porque cada worker do
gunicorn sobe a própria thread de consumo do SQS: mais réplica significa literalmente mais
gente puxando mensagem em paralelo, e quanto mais mensagem chega, mais CPU o pod gasta
processando e gravando no DynamoDB.

Eu deixei o `requests.cpu` baixo (100m) de propósito nesses dois. O HPA calcula a
utilização como percentual do *request*, não do limite - com um request alto, a carga da
demo nunca chegaria nos 70% e o gráfico não sairia da linha.

**Não usei KEDA**, e sei que ele seria melhor aqui. O KEDA olharia o `queueDepth` do SQS
direto e escalaria de 0 a N pelo número de mensagens esperando, que é o sinal real. A CPU
é um sinal indireto e atrasado: primeiro a fila enche, depois o pod trabalha mais, depois a
CPU sobe, depois o HPA reage. Escolhi HPA porque cabia no prazo e porque o desafio aceita
explicitamente esse caminho. Falo mais sobre isso no vídeo.

## Estrutura

```
.
├── auth-service/          Go   -> PostgreSQL
├── flag-service/          Py   -> PostgreSQL
├── targeting-service/     Py   -> PostgreSQL
├── evaluation-service/    Go   -> Redis + SQS (produtor)
├── analytics-service/     Py   -> SQS (consumidor) + DynamoDB
├── local/                 scripts de init dos bancos locais
├── k8s/                   manifestos do Kubernetes
└── docker-compose.yml     os 9 containers do ambiente local
```
