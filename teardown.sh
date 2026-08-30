#!/usr/bin/env bash
# Destroi tudo que foi criado na AWS pro Tech Challenge.
#
# ORDEM IMPORTA. O RDS e o ElastiCache tem interface de rede dentro das subnets da VPC
# que o eksctl criou. Se eles ainda existirem, o `eksctl delete cluster` trava tentando
# apagar a VPC e fica dando erro de dependencia. Entao: bancos primeiro, cluster depois.
set -uo pipefail

REGION=us-east-1
CLUSTER=togglemaster

echo "=== 1. nginx ingress (libera o Load Balancer) ==="
helm uninstall ingress-nginx -n ingress-nginx 2>/dev/null || echo "  ja removido"
kubectl delete ingress --all -A 2>/dev/null || true

echo "=== 2. RDS (3 instancias, sem snapshot final) ==="
for db in auth flags targeting; do
  aws rds delete-db-instance --db-instance-identifier "togglemaster-$db" \
    --skip-final-snapshot --delete-automated-backups --region $REGION >/dev/null 2>&1 \
    && echo "  apagando togglemaster-$db" || echo "  togglemaster-$db ja nao existe"
done

echo "=== 3. ElastiCache ==="
aws elasticache delete-replication-group --replication-group-id togglemaster-redis \
  --no-retain-primary-cluster --region $REGION >/dev/null 2>&1 \
  && echo "  apagando togglemaster-redis" || echo "  ja nao existe"

echo "=== 4. esperando os bancos sumirem (libera as interfaces de rede da VPC) ==="
while aws rds describe-db-instances --region $REGION \
        --query 'DBInstances[?starts_with(DBInstanceIdentifier, `togglemaster`)].DBInstanceIdentifier' \
        --output text 2>/dev/null | grep -q togglemaster; do
  echo "  ainda tem RDS de pe..."; sleep 30
done
while aws elasticache describe-replication-groups --replication-group-id togglemaster-redis \
        --region $REGION >/dev/null 2>&1; do
  echo "  elasticache ainda de pe..."; sleep 30
done
echo "  bancos removidos"

echo "=== 5. grupos de subnet e security groups criados na mao ==="
aws rds delete-db-subnet-group --db-subnet-group-name togglemaster-subnets --region $REGION >/dev/null 2>&1 || true
aws elasticache delete-cache-subnet-group --cache-subnet-group-name togglemaster-cache-subnets --region $REGION >/dev/null 2>&1 || true
for sg in togglemaster-rds-sg togglemaster-redis-sg; do
  id=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$sg" \
        --query 'SecurityGroups[0].GroupId' --output text --region $REGION 2>/dev/null)
  [ "$id" != "None" ] && [ -n "$id" ] && aws ec2 delete-security-group --group-id "$id" --region $REGION >/dev/null 2>&1 \
    && echo "  $sg removido"
done

echo "=== 6. cluster EKS (leva ~15min, apaga VPC, subnets, NAT e nodes) ==="
eksctl delete cluster --name $CLUSTER --region $REGION --disable-nodegroup-eviction 2>&1 | tail -5

echo "=== 6b. limpando o que o eksctl deixa pra tras ==="
# o eks-cluster-sg-* e criado e gerenciado pela AWS, nao pelo eksctl, entao nao faz parte
# da pilha. Ele fica orfao segurando a VPC, que segura a pilha em DELETE_FAILED.
# Aconteceu na primeira vez e travou tudo ate eu apagar na mao.
SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=eks-cluster-sg-*" \
      --query 'SecurityGroups[0].GroupId' --output text --region $REGION 2>/dev/null)
if [ -n "$SG" ] && [ "$SG" != "None" ]; then
  aws ec2 delete-security-group --group-id "$SG" --region $REGION >/dev/null 2>&1 \
    && echo "  security group orfao removido: $SG"
fi
VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=eksctl-$CLUSTER-cluster/VPC" \
       --query 'Vpcs[0].VpcId' --output text --region $REGION 2>/dev/null)
if [ -n "$VPC" ] && [ "$VPC" != "None" ]; then
  for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text --region $REGION 2>/dev/null); do
    aws ec2 delete-security-group --group-id "$sg" --region $REGION >/dev/null 2>&1
  done
  aws ec2 delete-vpc --vpc-id "$VPC" --region $REGION >/dev/null 2>&1 && echo "  VPC removida: $VPC"
  aws cloudformation delete-stack --stack-name "eksctl-$CLUSTER-cluster" --region $REGION >/dev/null 2>&1
fi

echo "=== 7. DynamoDB e SQS ==="
aws dynamodb delete-table --table-name ToggleMasterAnalytics --region $REGION >/dev/null 2>&1 \
  && echo "  tabela apagada" || echo "  tabela ja nao existe"
SQS=$(aws sqs get-queue-url --queue-name togglemaster-events --query QueueUrl --output text --region $REGION 2>/dev/null)
[ -n "$SQS" ] && [ "$SQS" != "None" ] && aws sqs delete-queue --queue-url "$SQS" --region $REGION >/dev/null 2>&1 \
  && echo "  fila apagada"

echo "=== 8. ECR (com as imagens dentro) ==="
for s in auth-service flag-service targeting-service evaluation-service analytics-service; do
  aws ecr delete-repository --repository-name "$s" --force --region $REGION >/dev/null 2>&1 \
    && echo "  $s removido"
done

echo "=== 9. usuario IAM da aplicacao ==="
for k in $(aws iam list-access-keys --user-name togglemaster-app --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
  aws iam delete-access-key --user-name togglemaster-app --access-key-id "$k" >/dev/null 2>&1
done
for p in AmazonSQSFullAccess AmazonDynamoDBFullAccess IAMUserChangePassword; do
  aws iam detach-user-policy --user-name togglemaster-app --policy-arn "arn:aws:iam::aws:policy/$p" >/dev/null 2>&1
done
aws iam delete-login-profile --user-name togglemaster-app >/dev/null 2>&1
aws iam delete-user --user-name togglemaster-app >/dev/null 2>&1 && echo "  usuario removido"

echo
echo "=== 10. varredura final por tag ==="
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=projeto,Values=techchallenge-fase2 \
  --query 'ResourceTagMappingList[].ResourceARN' --output text --region $REGION 2>/dev/null
echo
echo "=== conferir tambem no console: EC2 (volumes EBS orfaos, Load Balancers, Elastic IPs),"
echo "    VPC (NAT Gateway) e CloudWatch (log groups). E o Billing amanha."