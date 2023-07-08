#!/bin/bash

set -e
set -x

NODEJS_VERSION="${NODEJS_VERSION:-v14.19.1}"
NODE_PATH="${PWD}/nodejs"
CYPRESS_DOCKER_TYPE="${CYPRESS_DOCKER_TYPE:-included}"
CYPRESS_DOCKER_VERSION="${CYPRESS_DOCKER_VERSION:-12.3.0}"
CYPRESS_CONTAINER_NAME="${CYPRESS_CONTAINER_NAME:-cye2e}"
RANCHER_CONTAINER_NAME="${RANCHER_CONTAINER_NAME:-rancher}"
RANCHER_HOST_PORT_SECURE="${RANCHER_HOST_PORT:-4443}"
RANCHER_HOST_PORT="${RANCHER_HOST_PORT:-8887}"

export PATH="${NODE_PATH}/node-${NODEJS_VERSION}-linux-x64/bin:${PATH}"
export TEST_INSTRUMENT=true
./scripts/build-e2e

DIR=$(cd $(dirname $0)/..; pwd)
sudo chown -R $(whoami) .

DASHBOARD_DIST=${DIR}/dist
EMBER_DIST=${DIR}/dist_ember

docker run  --privileged -d -p "${RANCHER_HOST_PORT}:80" -p "${RANCHER_HOST_PORT_SECURE}:443" \
  -v ${DASHBOARD_DIST}:/usr/share/rancher/ui-dashboard/dashboard \
  -v ${EMBER_DIST}:/usr/share/rancher/ui \
  -e CATTLE_BOOTSTRAP_PASSWORD=password \
  -e CATTLE_UI_OFFLINE_PREFERRED=true \
  -e CATTLE_PASSWORD_MIN_LENGTH=3 \
  --name="${RANCHER_CONTAINER_NAME}" --restart=unless-stopped rancher/rancher:v2.7-head

RANCHER_CONTAINER_IP_FROM_HOST=$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' rancher)
RANCHER_CONTAINER_URL="https://${RANCHER_CONTAINER_IP_FROM_HOST}/dashboard/"

echo "Waiting for dashboard UI to be reachable (initial 20s wait) ..."
sleep 20
echo "Waiting for dashboard UI to be reachable ..."

okay=0

while [ $okay -lt 20 ]; do
  STATUS=$(curl --silent --head -k "${RANCHER_CONTAINER_URL}" | awk '/^HTTP/{print $2}')
  echo "Status: $STATUS (Try: $okay)"
  okay=$((okay+1))
  if [ "$STATUS" == "200" ]; then
    okay=100
  else
    sleep 5
  fi
done

if [ "$STATUS" != "200" ]; then
  echo "Dashboard did not become available in a reasonable time"
  exit 1
fi

echo "Dashboard UI is ready"

echo "Run Cypress"

docker build -f jenkins/Dockerfile.ci -t "cypress/${CYPRESS_DOCKER_TYPE}:${CYPRESS_DOCKER_VERSION}" .

RANCHER_CONTAINER_IP="127.0.0.1"
TEST_BASE_URL="https://${RANCHER_CONTAINER_IP}/dashboard"
TEST_USERNAME=admin
TEST_PASSWORD=password

docker run --network container:rancher --name "${CYPRESS_CONTAINER_NAME}" -t \
  -e CYPRESS_VIDEO=false \
  -e CYPRESS_VIEWPORT_WIDTH=1280 \
  -e CYPRESS_VIEWPORT_HEIGHT=720 \
  -e TEST_BASE_URL=${TEST_BASE_URL} \
  -e TEST_USERNAME=${TEST_USERNAME} \
  -e TEST_PASSWORD=${TEST_PASSWORD} \
  -e CATTLE_BOOTSTRAP_PASSWORD=${TEST_PASSWORD} \
  -v "${PWD}":/e2e \
  -w /e2e "cypress/${CYPRESS_DOCKER_TYPE}:${CYPRESS_DOCKER_VERSION}"

sudo chown -R $(whoami) .
jrm junit.xml "cypress/results/junit-*"
