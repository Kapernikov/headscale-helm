#!/bin/bash

# This script runs the helm-docs Docker image to generate documentation for the Helm chart.

# Define the path to your Helm chart
HELM_CHART_PATH="/home/kervel/projects/headscale-helm/headscale/"

# Define the output directory for the documentation (relative to the chart path)
# helm-docs generates README.md in the chart directory by default.
# If you want a different output directory, you can add -o <output_dir>
# For example: -o /docs

echo "Generating Helm chart documentation for: $HELM_CHART_PATH"

docker run --rm -v "${HELM_CHART_PATH}:/helm-docs" jnorwood/helm-docs:latest

echo "Helm chart documentation generated successfully in: $HELM_CHART_PATH"
