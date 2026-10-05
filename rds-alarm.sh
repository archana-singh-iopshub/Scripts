#!/bin/bash

set -e

# ============================================================
# RDS Dynamic CloudWatch Alarm Script
# ============================================================
# What this script does:
#
# 1. Discovers all RDS instances automatically.
# 2. Discovers SNS topic automatically from existing RDS alarms.
# 3. Checks CPU, Free Storage and Replica Lag alarms.
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

echo "✅ Existing CloudWatch alarms fetched."


# ------------------------------------------------------------
# Find SNS ARN for a particular DB
# ------------------------------------------------------------

get_db_sns_topic() {

    local DB_ID="$1"

    echo "$ALL_ALARMS" |
        jq -r --arg DB "$DB_ID" '
        .MetricAlarms[]
        | select(.Namespace == "AWS/RDS")
        | select(
            any(
                .Dimensions[]?;
                .Name == "DBInstanceIdentifier" and .Value == $DB
            )
        )
        | .AlarmActions[]?
        | select(startswith("arn:aws:sns:"))
        ' |
        sort |
        uniq -c |
        sort -nr |
        head -1 |
        awk '{print $2}'
}


# ------------------------------------------------------------
# Find most commonly used SNS for RDS alarms
# ------------------------------------------------------------

get_global_rds_sns_topic() {

    echo "$ALL_ALARMS" |
        jq -r '
        .MetricAlarms[]
        | select(.Namespace == "AWS/RDS")
        | .AlarmActions[]?
        | select(startswith("arn:aws:sns:"))
        ' |
        sort |
        uniq -c |
        sort -nr |
        head -1 |
        awk '{print $2}'
}


# ------------------------------------------------------------
# Find SNS topic
# ------------------------------------------------------------

echo ""
echo "=============================================="
echo "📢 Discovering SNS topic"
echo "=============================================="

GLOBAL_SNS_ARN=$(get_global_rds_sns_topic || true)

if [ -n "${GLOBAL_SNS_ARN:-}" ]; then

    echo "✅ RDS SNS discovered:"
    echo "   $GLOBAL_SNS_ARN"

else

    echo ""
    echo "❌ ERROR"
    echo "No SNS topic was found from existing RDS CloudWatch alarms."
    echo ""
    echo "The script will NOT randomly select an SNS topic."
    echo "Please configure at least one RDS alarm with the desired SNS topic"
    echo "and run this script again."
    exit 1

fi


# ------------------------------------------------------------
# Check whether an alarm already exists for DB + metric
# ------------------------------------------------------------

alarm_exists() {

    local DB_ID="$1"
    local METRIC_NAME="$2"

    echo "$ALL_ALARMS" |
        jq -e \
        --arg DB "$DB_ID" \
        --arg METRIC "$METRIC_NAME" '
        .MetricAlarms[]
        | select(.Namespace == "AWS/RDS")
        | select(.MetricName == $METRIC)
        | select(
            any(
                .Dimensions[]?;
                .Name == "DBInstanceIdentifier" and .Value == $DB
            )
        )
        ' >/dev/null
}


# ------------------------------------------------------------
# Create CPU alarm
# ------------------------------------------------------------

create_cpu_alarm() {

    local DB_ID="$1"
    local SNS_ARN="$2"

    local ALARM_NAME="${DB_ID}-RDSHighCPU"

    if alarm_exists "$DB_ID" "CPUUtilization"; then

        echo "✅ CPU alarm already exists for: $DB_ID"

        return 0
    fi

    echo "🚀 Creating CPU alarm for: $DB_ID"

    aws cloudwatch put-metric-alarm \
        --alarm-name "$ALARM_NAME" \
        --alarm-description "RDS CPU utilization is above ${CPU_THRESHOLD}% for ${DB_ID}" \
        --metric-name CPUUtilization \
        --namespace AWS/RDS \
        --statistic Average \
        --period "$PERIOD" \
        --evaluation-periods "$EVALUATION_PERIODS" \
        --threshold "$CPU_THRESHOLD" \
        --comparison-operator GreaterThanThreshold \
        --dimensions \
            Name=DBInstanceIdentifier,Value="$DB_ID" \
        --alarm-actions "$SNS_ARN" \
        --treat-missing-data notBreaching \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION"

    echo "✅ CPU alarm created: $ALARM_NAME"
}


# ------------------------------------------------------------
# Create Free Storage alarm
# ------------------------------------------------------------

create_storage_alarm() {

    local DB_ID="$1"
    local ALLOCATED_STORAGE="$2"
    local SNS_ARN="$3"

    local ALARM_NAME="${DB_ID}-RDSLowFreeStorage"

    if alarm_exists "$DB_ID" "FreeStorageSpace"; then

        echo "✅ Storage alarm already exists for: $DB_ID"

        return 0
    fi


    # Calculate 20% of allocated storage.
    #
    # RDS AllocatedStorage is GB.
    # CloudWatch FreeStorageSpace is bytes.
    #
    # GB -> bytes
    #

    local THRESHOLD_BYTES

    THRESHOLD_BYTES=$(awk \
        -v gb="$ALLOCATED_STORAGE" \
        -v percent="$FREE_STORAGE_PERCENT" \
        'BEGIN {
            printf "%.0f", gb * 1024 * 1024 * 1024 * percent / 100
        }')


    echo "🚀 Creating storage alarm for: $DB_ID"
    echo "   Allocated Storage : ${ALLOCATED_STORAGE} GB"
    echo "   Alarm Threshold   : ${FREE_STORAGE_PERCENT}% free"


    aws cloudwatch put-metric-alarm \
        --alarm-name "$ALARM_NAME" \
        --alarm-description "RDS free storage is below ${FREE_STORAGE_PERCENT}% for ${DB_ID}" \
        --metric-name FreeStorageSpace \
        --namespace AWS/RDS \
        --statistic Average \
        --period "$PERIOD" \
        --evaluation-periods "$EVALUATION_PERIODS" \
        --threshold "$THRESHOLD_BYTES" \
        --comparison-operator LessThanThreshold \
        --dimensions \
            Name=DBInstanceIdentifier,Value="$DB_ID" \
        --alarm-actions "$SNS_ARN" \
        --treat-missing-data notBreaching \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION"

    echo "✅ Storage alarm created: $ALARM_NAME"
}


# ------------------------------------------------------------
# Create Replica Lag alarm
# ------------------------------------------------------------

create_replica_lag_alarm() {

    local DB_ID="$1"
    local SNS_ARN="$2"

    local ALARM_NAME="${DB_ID}-RDSHighReplicaLag"


    if alarm_exists "$DB_ID" "ReplicaLag"; then

        echo "✅ Replica lag alarm already exists for: $DB_ID"

        return 0
    fi


    echo "🚀 Creating replica lag alarm for: $DB_ID"


    aws cloudwatch put-metric-alarm \
        --alarm-name "$ALARM_NAME" \
        --alarm-description "RDS replica lag is above ${REPLICA_LAG_THRESHOLD} seconds for ${DB_ID}" \
        --metric-name ReplicaLag \
        --namespace AWS/RDS \
        --statistic Average \
        --period "$PERIOD" \
        --evaluation-periods "$EVALUATION_PERIODS" \
        --threshold "$REPLICA_LAG_THRESHOLD" \
        --comparison-operator GreaterThanThreshold \
        --dimensions \
            Name=DBInstanceIdentifier,Value="$DB_ID" \
        --alarm-actions "$SNS_ARN" \
        --treat-missing-data notBreaching \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION"

    echo "✅ Replica lag alarm created: $ALARM_NAME"
}


# ------------------------------------------------------------
# Discover ALL RDS instances
# ------------------------------------------------------------

echo ""
echo "=============================================="
echo "🗄️ Discovering RDS databases"
echo "=============================================="

RDS_DATA=$(aws rds describe-db-instances \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query 'DBInstances[*].[DBInstanceIdentifier,AllocatedStorage,ReadReplicaSourceDBInstanceIdentifier]' \
    --output json)


RDS_COUNT=$(echo "$RDS_DATA" | jq 'length')


if [ "$RDS_COUNT" -eq 0 ]; then

    echo "❌ No RDS instances found."

    exit 0
fi


echo "✅ Total RDS instances found: $RDS_COUNT"


# ------------------------------------------------------------
# Process every RDS DB
# ------------------------------------------------------------

echo "$RDS_DATA" |
jq -c '.[]' |
while read -r DB_INFO
do

    DB_ID=$(echo "$DB_INFO" | jq -r '.[0]')
    ALLOCATED_STORAGE=$(echo "$DB_INFO" | jq -r '.[1]')
    REPLICA_SOURCE=$(echo "$DB_INFO" | jq -r '.[2]')


    echo ""
    echo "=============================================="
    echo "🗄️ Processing DB: $DB_ID"
    echo "=============================================="


    # --------------------------------------------------------
    # Find SNS specifically associated with this DB
    # --------------------------------------------------------

    DB_SNS_ARN=$(get_db_sns_topic "$DB_ID" || true)


    if [ -n "${DB_SNS_ARN:-}" ]; then

        SNS_ARN="$DB_SNS_ARN"

        echo "📢 SNS found for this DB:"
        echo "   $SNS_ARN"

    else

        SNS_ARN="$GLOBAL_SNS_ARN"

        echo "📢 No DB-specific SNS found."
        echo "   Using common RDS SNS:"
        echo "   $SNS_ARN"

    fi


    # --------------------------------------------------------
    # CPU Alarm
    # --------------------------------------------------------

    create_cpu_alarm \
        "$DB_ID" \
        "$SNS_ARN"


    # --------------------------------------------------------
    # Storage Alarm
    # --------------------------------------------------------

    create_storage_alarm \
        "$DB_ID" \
        "$ALLOCATED_STORAGE" \
        "$SNS_ARN"


    # --------------------------------------------------------
    # Replica Lag Alarm
    # --------------------------------------------------------

    if [ "$REPLICA_SOURCE" != "null" ] &&
       [ "$REPLICA_SOURCE" != "None" ] &&
       [ -n "$REPLICA_SOURCE" ]; then

        echo "🔄 Read Replica detected."
        echo "   Source DB: $REPLICA_SOURCE"

        create_replica_lag_alarm \
            "$DB_ID" \
            "$SNS_ARN"

    else

        echo "ℹ️ Not a read replica."
        echo "   ReplicaLag alarm skipped."

    fi

done


# ------------------------------------------------------------
# Final message
# ------------------------------------------------------------

echo ""
echo "=============================================="
echo "🎉 RDS ALARM CHECK COMPLETED"
echo "=============================================="

echo ""
echo "Summary:"
echo "✔ All RDS DBs discovered automatically"
echo "✔ Existing alarms preserved"
echo "✔ Missing CPU alarms created"
echo "✔ Missing storage alarms created"
echo "✔ ReplicaLag alarms created only for replicas"
echo "✔ SNS discovered automatically"
echo "✔ No DB name hardcoded"
echo "✔ No SNS topic hardcoded"
echo ""
