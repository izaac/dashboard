#!/bin/bash

set -e

pwd
cd "dashboard"

kubectl version --client=true
kubectl get nodes

node -v

env

export NO_COLOR=1
export PERCY_CLIENT_ERROR_LOGS=false
CYPRESS_grepTags="CYPRESSTAGS" npx --no-install percy exec -- cypress run --browser chrome --config-file cypress/jenkins/cypress.config.jenkins.ts

echo "CYPRESS EXIT CODE: $?"
