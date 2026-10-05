#!/bin/bash

set -e

# ============================================================
# RDS Dynamic CloudWatch Alarm Script
# ============================================================
# What this script does:
#
# 1. Discovers all RDS instances automatically.
# 2. Discovers SNS topic automatically from existing RDS alarms.
# 3. Checks CPU, Free Storage, Free Memory, Connections and Replica Lag alarms.
# 4. Creates ONLY missing alarms.
# 5. Does not modify/delete existing alarms.
# 6. Does not hardcode DB names.
# 7. Does not hardcode SNS topic name/ARN.
#
# Requirements:
#   - AWS CLI
#   - jq
#   - AWS credentials/profile with:
#       rds:DescribeDBInstances
#       cloudwatch:DescribeAlarms
#       cloudwatch:PutMetricAlarm
# ============================================================


# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

AWS_PROFILE="brands-prod"
AWS_REGION="ap-south-1"

CPU_THRESHOLD=80

# Free storage threshold = 20% of allocated storage
FREE_STORAGE_PERCENT=20
FREE_MEMORY_PERCENT=20
CONNECTIONS_THRESHOLD=100

REPLICA_LAG_THRESHOLD=60

EVALUATION_PERIODS=2
PERIOD=300


# ------------------------------------------------------------
# Check dependencies
# ------------------------------------------------------------

if ! command -v aws >/dev/null 2>&1; then
    echo "❌ AWS CLI is not installed."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "❌ jq is not installed."
    echo "Install jq first:"
    echo "sudo apt-get install -y jq"
    exit 1
fi


# ------------------------------------------------------------
# Verify AWS access
# ------------------------------------------------------------

echo ""
echo "=============================================="
echo "🔐 Checking AWS credentials"
echo "=============================================="

ACCOUNT_ID=$(aws sts get-caller-identity \
    --profile "$AWS_PROFILE" \
    --query 'Account' \
    --output text)

echo "✅ AWS Account : $ACCOUNT_ID"
echo "✅ AWS Region  : $AWS_REGION"
echo "✅ AWS Profile : $AWS_PROFILE"


# ------------------------------------------------------------
# Get all existing CloudWatch alarms
# ------------------------------------------------------------

echo ""
echo "=============================================="
echo "🔍 Fetching existing CloudWatch alarms"
echo "=============================================="

ALL_ALARMS=$(aws cloudwatch describe-alarms \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --output json)
