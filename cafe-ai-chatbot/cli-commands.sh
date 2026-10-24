#!/usr/bin/env bash
# Cafe AI Order Assistant — full build script.
# Run from the CLI Host instance (or anywhere with AWS CLI configured
# for this account), after completing the base lab through Task 3.
#
# Fill in the variables below first, then run step by step (don't
# blindly pipe this whole file — read README.md alongside it).

set -euo pipefail

REGION="us-east-1"                 # match the lab's region
ACCOUNT_ID="<ACCOUNT_ID>"
VPC_ID="<CafeVpcId>"
PRIVATE_SUBNET_1="<CafePrivateSubnet1>"
PRIVATE_SUBNET_2="<CafePrivateSubnet2>"
DB_SECURITY_GROUP="<CafeDatabaseSG>"
RDS_ENDPOINT="<rds-endpoint>"
RDS_USERNAME="admin"
RDS_PASSWORD="<rds-password>"
BEDROCK_MODEL_ID="anthropic.claude-3-5-haiku-20241022-v1:0"

# 1. Secrets Manager: store RDS credentials
aws secretsmanager create-secret \
  --name cafe-rds-credentials \
  --description "Credentials for Cafe RDS MariaDB instance" \
  --secret-string "{\"username\":\"${RDS_USERNAME}\",\"password\":\"${RDS_PASSWORD}\",\"host\":\"${RDS_ENDPOINT}\"}"

SECRET_ARN=$(aws secretsmanager describe-secret --secret-id cafe-rds-credentials --query 'ARN' --output text)

# 2. IAM role for the Lambda function
aws iam create-role \
  --role-name CafeChatbotLambdaRole \
  --assume-role-policy-document file://lambda/lambda-trust-policy.json

aws iam put-role-policy \
  --role-name CafeChatbotLambdaRole \
  --policy-name CafeChatbotLambdaPolicy \
  --policy-document file://iam/cafe-chatbot-lambda-policy.json

# Give IAM a few seconds to propagate before Lambda creation references the role.
sleep 10

# 3. Security group for the chatbot Lambda + open DB access to it
CHATBOT_SG=$(aws ec2 create-security-group \
  --group-name CafeChatbotSG \
  --description "Cafe chatbot Lambda ENIs" \
  --vpc-id "${VPC_ID}" \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "${DB_SECURITY_GROUP}" \
  --protocol tcp --port 3306 \
  --source-group "${CHATBOT_SG}"

# 4. Private connectivity to Bedrock and Secrets Manager (no NAT Gateway needed)
aws ec2 create-vpc-endpoint \
  --vpc-id "${VPC_ID}" \
  --service-name "com.amazonaws.${REGION}.bedrock-runtime" \
  --vpc-endpoint-type Interface \
  --subnet-ids "${PRIVATE_SUBNET_1}" "${PRIVATE_SUBNET_2}" \
  --security-group-ids "${CHATBOT_SG}"

aws ec2 create-vpc-endpoint \
  --vpc-id "${VPC_ID}" \
  --service-name "com.amazonaws.${REGION}.secretsmanager" \
  --vpc-endpoint-type Interface \
  --subnet-ids "${PRIVATE_SUBNET_1}" "${PRIVATE_SUBNET_2}" \
  --security-group-ids "${CHATBOT_SG}"

# 5. Package and deploy the Lambda function
pushd lambda
pip install pymysql -t ./package --platform manylinux2014_x86_64 --only-binary=:all: --python-version 3.12
cp chatbot_handler.py ./package/
(cd package && zip -r ../chatbot_handler.zip .)
popd

aws lambda create-function \
  --function-name CafeChatbotFunction \
  --runtime python3.12 \
  --handler chatbot_handler.handler \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/CafeChatbotLambdaRole" \
  --zip-file fileb://lambda/chatbot_handler.zip \
  --timeout 15 \
  --memory-size 256 \
  --vpc-config "SubnetIds=${PRIVATE_SUBNET_1},${PRIVATE_SUBNET_2},SecurityGroupIds=${CHATBOT_SG}" \
  --environment "Variables={BEDROCK_MODEL_ID=${BEDROCK_MODEL_ID},DB_SECRET_ARN=${SECRET_ARN}}"

# 6. API Gateway HTTP API in front of the Lambda
API_ID=$(aws apigatewayv2 create-api \
  --name CafeChatbotApi \
  --protocol-type HTTP \
  --target "arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:CafeChatbotFunction" \
  --query 'ApiId' --output text)

aws lambda add-permission \
  --function-name CafeChatbotFunction \
  --statement-id apigateway-invoke \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*/chat"

echo "Chat endpoint:"
aws apigatewayv2 get-apis --query "Items[?ApiId=='${API_ID}'].ApiEndpoint" --output text
echo "(append /chat to the URL above, and paste it into web/chatbot-widget.html)"
