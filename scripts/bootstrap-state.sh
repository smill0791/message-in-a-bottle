#!/usr/bin/env bash
# Create the S3 bucket that holds Terraform state.
#
# Chicken-and-egg: the backend has to exist before Terraform can use it, so
# this one piece is created with the CLI and never managed by Terraform. That
# is deliberate - a state bucket managed by the state it stores is a bootstrap
# problem waiting to happen, and `terraform destroy` would take the state with
# it.
#
# Safe to re-run.

set -euo pipefail

REGION="${AWS_REGION:-us-east-2}"
ACCOUNT="116307287000"
BUCKET="bottle-tfstate-${ACCOUNT}-${REGION}"

# The AWS CLI reads AWS_PROFILE from the environment on its own, so no command
# below needs --profile. This only supplies the local default; under OIDC in CI
# there is no ~/.aws/config, and naming a profile would fail every call.
if [[ -z "${AWS_PROFILE:-}" && -z "${CI:-}" ]]; then
    export AWS_PROFILE=aws-dev-project
fi

echo "bucket: $BUCKET"

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    echo "already exists"
else
    aws s3api create-bucket \
        --bucket "$BUCKET" \
        --region "$REGION" \
        --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
    echo "created"
fi

# Versioning: state corruption is recoverable only if old versions survive.
aws s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled

# State contains database passwords and connection strings in plaintext.
aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Old state versions have no value after a month and cost money to keep.
aws s3api put-bucket-lifecycle-configuration \
    --bucket "$BUCKET" \
    --lifecycle-configuration '{
        "Rules": [{
            "ID": "expire-old-state-versions",
            "Status": "Enabled",
            "Filter": {"Prefix": ""},
            "NoncurrentVersionExpiration": {"NoncurrentDays": 30},
            "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}
        }]
    }'

echo "versioning, encryption, public access block and lifecycle applied"
