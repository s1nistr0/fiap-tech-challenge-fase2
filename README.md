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

## Os 5 serviços

Eu venho de infraestrutura, não de desenvolvimento. Então pra entender o que cada serviço
faz, fui procurando paralelo com coisa que eu já mexo no dia a dia. Deixo aqui do jeito que
fez sentido pra mim, com um exemplo prático de cada um.

<details open>
<summary><b>auth-service</b> (Go, porta 8001) - quem valida a chave</summary>

Ele guarda chaves de API e responde uma pergunta só: "essa chave é válida?". Os outros
serviços perguntam pra ele antes de deixar qualquer requisição passar.

O paralelo que me ajudou: é um token de API, tipo o token que a gente gera pra integrar
com a API do Zabbix. Quem tem o token, entra; quem não tem, toma 401.

Uma coisa que eu achei boa no código: ele **nunca guarda a chave**, só o hash SHA-256 dela.
Se alguém der um SELECT na tabela, vê `a65bbb05a4...` e não consegue fazer nada com isso.
Quando você cria uma chave, ele te mostra em texto plano uma vez e nunca mais.

```bash
# criar uma chave (precisa da MASTER_KEY, que e a senha de admin do servico)
curl -X POST http://localhost:8001/admin/keys \
  -H "Authorization: Bearer admin-secreto-123" \
  -H 'Content-Type: application/json' -d '{"name":"minha-app"}'
```
```json
{"name":"minha-app","key":"tm_key_9f3a...","message":"Guarde esta chave com seguranca!..."}
```

</details>

<details>
<summary><b>flag-service</b> (Python, porta 8002) - o cadastro das flags</summary>

É o CRUD: criar, listar, editar e apagar flag. Cada flag tem nome, descrição e um
`is_enabled`, que é o interruptor geral. Se estiver desligado aqui, está desligado pra todo
mundo, não importa mais nenhuma regra.

O paralelo: é o *kill switch*. Igual quando a gente desabilita uma tarefa agendada ou para
um serviço no Windows - não interessa a configuração dele, parou pra geral.

```bash
# cadastrar a flag do novo dashboard, ja ligada
curl -X POST http://localhost:8002/flags \
  -H "Authorization: Bearer tm_key_local_dev_123" -H 'Content-Type: application/json' \
  -d '{"name":"enable-new-dashboard","description":"dashboard novo","is_enabled":true}'
```

</details>

<details>
<summary><b>targeting-service</b> (Python, porta 8003) - pra quem a flag vale</summary>

A flag estar ligada não quer dizer que todo mundo recebe. Aqui é onde fica a regra de
*quem* recebe. Hoje o código só entende um tipo: porcentagem.

O paralelo: é o anel de piloto de um rollout. Quando a gente vai aplicar patch, não joga em
600 máquinas de uma vez - manda pra 5%, olha se quebrou, e só depois abre pro resto. É
exatamente isso, só que pra funcionalidade em vez de patch.

A regra fica num campo JSONB do PostgreSQL, e eu achei isso esperto: se amanhã quiserem uma
regra por lista de usuário ou por país, é só gravar outro JSON, não precisa alterar a
tabela.

```bash
# essa flag vale pra 50% dos usuarios
curl -X POST http://localhost:8003/rules \
  -H "Authorization: Bearer tm_key_local_dev_123" -H 'Content-Type: application/json' \
  -d '{"flag_name":"enable-new-dashboard","rules":{"type":"PERCENTAGE","value":50}}'
```

</details>

<details>
<summary><b>evaluation-service</b> (Go, porta 8004) - quem responde sim ou não</summary>

Esse é o que aguenta o tranco. Todos os outros são chamados de vez em quando; esse é
chamado toda vez que alguém abre a tela. Por isso o desafio chama ele de *caminho quente*.

Duas coisas que ele faz pra dar conta:

**Cache no Redis.** Em vez de perguntar pro flag-service e pro targeting-service a cada
chamada, ele pergunta uma vez, junta as duas respostas e guarda no Redis por 30 segundos. O
paralelo é o TTL de DNS: você não consulta o servidor DNS a cada pacote, resolve uma vez e
guarda um tempo.

**Resposta determinística.** Ele pega `user_id + flag_name`, calcula um hash, tira o módulo
100 e compara com a porcentagem. O mesmo usuário sempre cai no mesmo número. Isso importa
mais do que parece: se fosse sorteio aleatório, o usuário veria o botão aparecer e sumir a
cada F5.

```bash
curl "http://localhost:8004/evaluate?user_id=user-1&flag_name=enable-new-dashboard"
# {"flag_name":"enable-new-dashboard","user_id":"user-1","result":true}

curl "http://localhost:8004/evaluate?user_id=user-abc&flag_name=enable-new-dashboard"
# {"flag_name":"enable-new-dashboard","user_id":"user-abc","result":false}
```

Rode o mesmo `user-1` dez vezes: dá `true` nas dez.

</details>

<details>
<summary><b>analytics-service</b> (Python, porta 8005) - o histórico, fora do caminho</summary>

Toda vez que o evaluation responde alguma coisa, ele joga um evento numa fila. Esse serviço
fica lendo a fila e gravando no DynamoDB, pra depois alguém conseguir responder "quantos
usuários viram o dashboard novo essa semana".

O detalhe importante é que ele **não fica no caminho da requisição**. O paralelo mais
próximo do meu dia a dia é a coleta do Zabbix: o agente coleta e manda pro servidor, e se o
servidor Zabbix cair, a aplicação monitorada continua funcionando normalmente. Aqui é
igual - se esse serviço morrer, ninguém que está usando o produto percebe. As mensagens
ficam esperando na fila e ele processa quando voltar.

Ele nem tem endpoint de negócio, só o `/health`:

```bash
curl http://localhost:8005/health
# {"status":"ok"}
```

O trabalho de verdade acontece numa thread em segundo plano, com long polling na fila.

</details>

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
