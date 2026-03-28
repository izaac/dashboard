#!/bin/bash

set -e

# Source shared utilities relative to the script's location
source "$(dirname "$0")/utils.sh"

pwd
cd "dashboard"

kubectl version --client=true
kubectl get nodes

node -v

env

export FORCE_COLOR=1
export PERCY_LOGLEVEL=warn
export PERCY_SKIP_UPDATE_CHECK=true
export DEBUG=@cypress/grep

# Capture the tags from the placeholder (replaced by playbook setup-test-env.yml)
TAGS="CYPRESSTAGS"

# Normalize tags (strip @bypass, handle spaces)
TAGS=$(clean_tags "${TAGS}")

export CYPRESS_grepTags="$TAGS"

# Pre-filter specs by tag so Cypress only opens matching files.
# This bypasses the Cypress 11 bug where config.specPattern modifications
# from setupNodeEvents are ignored.
SPEC_ARG=()
if [ -n "$TAGS" ]; then
	FILTERED_SPECS=$(node --experimental-strip-types cypress/jenkins/grep-filter.ts)
	if [ -n "$FILTERED_SPECS" ]; then
		echo "grep-filter: will run --spec $FILTERED_SPECS"
		SPEC_ARG=(--spec "$FILTERED_SPECS")
	else
		echo "grep-filter: no matching specs found for tags '$TAGS', running all specs"
	fi
fi

# Run Cypress and capture the exit code
set +e

if [ -n "$PERCY_TOKEN" ]; then
	npx --no-install percy exec -q -- cypress run --browser chrome --config-file cypress/jenkins/cypress.config.jenkins.ts "${SPEC_ARG[@]}"
else
	npx --no-install cypress run --browser chrome --config-file cypress/jenkins/cypress.config.jenkins.ts "${SPEC_ARG[@]}"
fi
EXIT_CODE=$?
set -e

# Merge JUnit XML reports into a single file for Jenkins
echo "Merging JUnit reports..."
if ! npx --no-install jrm results.xml "cypress/jenkins/reports/junit/junit-*"; then
  echo "WARNING: jrm merge failed — individual junit-*.xml files may still be available"
  ls -la cypress/jenkins/reports/junit/ 2>/dev/null || echo "  (report directory not found)"
fi

echo "CYPRESS EXIT CODE: $EXIT_CODE"
exit $EXIT_CODE
