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
REGION="${AWS_REGION:-us-east-2}"

# The AWS CLI reads AWS_PROFILE from the environment by itself, so nothing here
# needs to pass --profile. All this does is supply the local default.
#
# In CI there must be no profile at all: credentials arrive from OIDC role
# assumption and live in the environment, and naming a profile that has no
# entry in ~/.aws/config fails the command outright.
if [[ -z "${AWS_PROFILE:-}" && -z "${CI:-}" ]]; then
    export AWS_PROFILE=aws-dev-project
fi

trap 'rm -rf "$STAGE"' EXIT

# --upload-only exists so the pipeline can build the artifact once and ship
# those exact bytes.
#
# Rebuilding in the deploy job would mean the thing tested and the thing
# deployed are two different compilations of the same source - usually
# identical, occasionally not, and the difference only ever shows up in
# production. It also needs no Node toolchain in the deploy job at all.
MODE="both"
case "${1:-}" in
    --no-upload) MODE="build" ;;
    --upload-only) MODE="upload" ;;
    "") ;;
    *)
        echo "unknown option: $1" >&2
        echo "usage: package.sh [--no-upload | --upload-only]" >&2
        exit 1
        ;;
esac

if [[ "$MODE" == "upload" ]]; then
    if [[ ! -f "$TARBALL" ]]; then
        echo "no artifact at $TARBALL - nothing to upload." >&2
        echo "run package.sh --no-upload first, or pass the build artifact through." >&2
        exit 1
    fi
    echo "=== using prebuilt $TARBALL ==="
else
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

    # Migrations travel with the artifact so the schema and the code that
    # expects it can never drift apart.
    cp -R db/migrations "$STAGE/db/migrations"

    # Seeds travel too, for the same reason and one more: it is what makes
    # `remote-admin.sh seed` possible without shipping a file to the instance
    # separately. The messages that set the tone of the app arrive with the
    # deployment that serves them.
    cp -R db/seeds "$STAGE/db/seeds"

    mkdir -p "$ROOT/dist"
    # COPYFILE_DISABLE stops macOS tar embedding AppleDouble/xattr headers,
    # which GNU tar on the instance warns about for every single file.
    COPYFILE_DISABLE=1 tar --no-xattrs -czf "$TARBALL" -C "$STAGE" .

    size=$(du -h "$TARBALL" | cut -f1)
    echo "built $TARBALL ($size)"
fi

if [[ "$MODE" == "build" ]]; then
    echo "skipping upload"
    exit 0
fi

BUCKET="${ARTIFACT_BUCKET:-}"

if [[ -z "$BUCKET" ]]; then
    # Terraform's output, when there is a local state to read it from.
    BUCKET=$(terraform -chdir=infra output -raw artifact_bucket 2>/dev/null || true)
fi

if [[ -z "$BUCKET" ]]; then
    # Derive it. The bucket name is account-scoped by construction in
    # infra/main.tf, so this is the same string Terraform would produce - and
    # it works in CI, where there is no local Terraform state to query and the
    # deploy job has no Terraform binary anyway.
    account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
    [[ -n "$account" ]] && BUCKET="bottle-artifacts-${account}"
fi

if [[ -z "$BUCKET" ]]; then
    echo "no artifact bucket found." >&2
    echo "set ARTIFACT_BUCKET, or apply the stack first so the output exists." >&2
    exit 1
fi

echo "=== uploading to s3://$BUCKET/$KEY ==="
aws s3 cp "$TARBALL" "s3://$BUCKET/$KEY" --region "$REGION"
echo "uploaded"
