#!/bin/bash

# Exit on error
set -e

# Required environment variables
: "${GCP_PROJECT_ID:?'GCP_PROJECT_ID is required'}"
: "${GCP_SERVICE_ACCOUNT:?'GCP_SERVICE_ACCOUNT is required'}"
: "${GCP_REGION:?'GCP_REGION is required'}"
: "${DOCKER_REGISTRY:?'DOCKER_REGISTRY is required'}"
: "${IMAGE_NAME:?'IMAGE_NAME is required'}"
: "${GITHUB_TOKEN_SECRET_NAME:?'GITHUB_TOKEN_SECRET_NAME is required'}"

# Generate Cloud Run config from template
CONFIG_FILE="src/configs/cloud-run.yml"
TEMP_CONFIG="/tmp/cloud-run-config.yml"

# Replace environment variables in the config
envsubst < "${CONFIG_FILE}" > "${TEMP_CONFIG}"

# Deploy to Cloud Run using gcloud beta for YAML support
gcloud beta run services replace "${TEMP_CONFIG}" \
  --platform=managed \
  --region=${GCP_REGION} \
  --project="${GCP_PROJECT_ID}"

# Clean up temp file
rm -f "${TEMP_CONFIG}"

# Get the endpoint
HTTPS_ENDPOINT=$(gcloud run services describe ${IMAGE_NAME} --platform managed --region ${GCP_REGION} --format 'value(status.url)')

echo "Deployment complete!"
echo "HTTPS Endpoint: ${HTTPS_ENDPOINT}"
echo "Note: Cloud Run does not support TCP ports (like SSH port 22). For SSH access, consider using Google Compute Engine instead."
