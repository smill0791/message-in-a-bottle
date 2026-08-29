#!/usr/bin/env bash
# Build the application and upload the deployment artifact to S3.
#
#   ./scripts/package.sh              # build and upload
#   ./scripts/package.sh --no-upload  # build the tarball only
#
# The tarball ships source-free build output plus the lockfile. Dependencies
# are installed on the instance rather than bundled: a node_modules tree built
# on macOS can contain platform-specific binaries that will not run on Linux
# arm64, and that failure surfaces as a confusing crash at boot rather than an
# obvious build error.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
STAGE=$(mktemp -d)
TARBALL="$ROOT/dist/app.tar.gz"
KEY="app/latest.tar.gz"
PROFILE="${AWS_PROFILE:-aws-dev-project}"
REGION="us-east-2"

trap 'rm -rf "$STAGE"' EXIT

echo "=== building ==="
npm run build --workspace api
npm run build --workspace web

echo "=== staging ==="
mkdir -p "$STAGE"/{api,web,db}

# Lockfile and manifests, so `npm ci` on the instance resolves exactly the
# versions that were tested here.
cp package.json package-lock.json "$STAGE/"
cp api/package.json "$STAGE/api/"
cp web/package.json "$STAGE/web/"

cp -R api/dist "$STAGE/api/dist"
cp -R web/dist "$STAGE/web/dist"

# Migrations travel with the artifact so the schema and the code that expects
# it can never drift apart.
cp -R db/migrations "$STAGE/db/migrations"

mkdir -p "$ROOT/dist"
tar -czf "$TARBALL" -C "$STAGE" .

size=$(du -h "$TARBALL" | cut -f1)
echo "built $TARBALL ($size)"

if [[ "${1:-}" == "--no-upload" ]]; then
    echo "skipping upload"
    exit 0
fi

BUCKET="${ARTIFACT_BUCKET:-}"
if [[ -z "$BUCKET" ]]; then
    # Fall back to the Terraform output so this works without arguments once
    # the stack exists.
    BUCKET=$(terraform -chdir=infra output -raw artifact_bucket 2>/dev/null || true)
fi

if [[ -z "$BUCKET" ]]; then
    echo "no artifact bucket found." >&2
    echo "set ARTIFACT_BUCKET, or apply the stack first so the output exists." >&2
    exit 1
fi

echo "=== uploading to s3://$BUCKET/$KEY ==="
aws s3 cp "$TARBALL" "s3://$BUCKET/$KEY" --region "$REGION" --profile "$PROFILE"
echo "uploaded"
