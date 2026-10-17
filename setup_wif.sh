#!/usr/bin/env bash
set -euo pipefail

# Workload Identity Federation (WIF) Setup Script for Google Cloud & GitHub Actions
# Target Repository: shansri-google/CodeMender

if [ $# -lt 1 ]; then
    echo "Usage: ./setup_wif.sh <YOUR_GCP_PROJECT_ID>"
    echo "Example: ./setup_wif.sh my-gcp-security-project"
    exit 1
fi

PROJECT_ID="$1"
REPO="shansri-google/CodeMender"
POOL_NAME="github-codemender-pool"
PROVIDER_NAME="github-codemender-provider"
SA_NAME="codemender-cicd-sa"

echo "Setting active GCP project to ${PROJECT_ID}..."
gcloud config set project "${PROJECT_ID}"

echo "1. Enabling required GCP APIs..."
gcloud services enable iamcredentials.googleapis.com \
    aiplatform.googleapis.com \
    cloudresourcemanager.googleapis.com

echo "2. Creating Service Account: ${SA_NAME}..."
gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="CodeMender CI/CD Service Account" 2>/dev/null || echo "Service account already exists"

echo "3. Granting Vertex AI User role to Service Account..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/aiplatform.user" > /dev/null

echo "4. Creating Workload Identity Pool..."
gcloud iam workload-identity-pools create "${POOL_NAME}" \
    --location="global" \
    --display-name="GitHub Actions CodeMender Pool" 2>/dev/null || echo "Workload Identity Pool already exists"

POOL_ID=$(gcloud iam workload-identity-pools describe "${POOL_NAME}" \
    --location="global" --format="value(name)")

echo "5. Creating OIDC Provider for GitHub..."
gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_NAME}" \
    --location="global" \
    --workload-identity-pool="${POOL_NAME}" \
    --display-name="GitHub Provider" \
    --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
    --attribute-condition="assertion.repository == '${REPO}'" \
    --issuer-uri="https://token.actions.githubusercontent.com" 2>/dev/null || echo "Provider already exists"

echo "6. Binding GitHub repository (${REPO}) to Service Account..."
gcloud iam service-accounts add-iam-policy-binding \
    "${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/${POOL_ID}/attribute.repository/${REPO}" > /dev/null

echo ""
echo "=========================================================================="
echo "🎉 WIF SETUP SUCCESSFUL!"
echo ""
echo "Navigate to GitHub Secrets Settings:"
echo "👉 https://github.com/shansri-google/CodeMender/settings/secrets/actions"
echo ""
echo "Add the following 3 Repository Secrets:"
echo "--------------------------------------------------------------------------"
echo "Secret Name: GCP_PROJECT_ID"
echo "Secret Value: ${PROJECT_ID}"
echo ""
echo "Secret Name: WIF_SERVICE_ACCOUNT"
echo "Secret Value: ${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
echo ""
echo "Secret Name: WIF_PROVIDER"
echo "Secret Value: ${POOL_ID}/providers/${PROVIDER_NAME}"
echo "=========================================================================="
