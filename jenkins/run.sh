#!/bin/bash

shopt -s extglob
set -e
set -x

if [ -f ".env" ]; then
    set -a;
    source .env;
    set +a; 
fi

CYPRESS_DOCKER_TYPE="${CYPRESS_DOCKER_TYPE:-included}"
CYPRESS_DOCKER_VERSION="${CYPRESS_DOCKER_VERSION:-12.3.0}"
CYPRESS_CONTAINER_NAME="${CYPRESS_CONTAINER_NAME:-cye2e}"
CYPRESS_DOCKER_OWNER="cypress-io"
CYPRESS_DOCKER_REPO="cypress-docker-images"
CYPRESS_DOCKER_BRANCH="${CYPRESS_DOCKER_BRANCH:-master}"
GITHUB_CODELOAD_URL="https://codeload.github.com"
GITHUB_CODELOAD_PATH="${GITHUB_CODELOAD_URL}/${CYPRESS_DOCKER_OWNER}/${CYPRESS_DOCKER_REPO}"
NODEJS_VERSION="${NODEJS_VERSION:-v14.19.1}"
NODE_PATH="${PWD}/nodejs"
NODEJS_FILE="node-${NODEJS_VERSION}-linux-x64.tar.xz"
NODEJS_DOWNLOAD_URL="https://nodejs.org/dist"
RANCHER_CONTAINER_NAME="${RANCHER_CONTAINER_NAME:-rancher}"

env

setup () {
  if [ -f "${NODEJS_FILE}" ]; then rm -r "${NODEJS_FILE}"; fi
  curl -L --silent -o "${NODEJS_FILE}" \
    "${NODEJS_DOWNLOAD_URL}/${NODEJS_VERSION}/${NODEJS_FILE}"

  NODE_PATH="${PWD}/nodejs"
  mkdir -p ${NODE_PATH}
  tar -xJf "${NODEJS_FILE}" -C ${NODE_PATH}
  export PATH="${NODE_PATH}/node-${NODEJS_VERSION}-linux-x64/bin:${PATH}"
  npm_config_loglevel=error

  cd dashboard
  echo "${PWD}"
  node -v
  npm version
  npm install -g yarn
  npm install -g junit-report-merger

  if [ -d "${CYPRESS_DOCKER_VERSION}" ]; then rm -r ${CYPRESS_DOCKER_VERSION}; fi

  curl --silent "${GITHUB_CODELOAD_PATH}/tar.gz/master" | \
    tar -xz --strip=2 \
    "${CYPRESS_DOCKER_REPO}-${CYPRESS_DOCKER_BRANCH}/${CYPRESS_DOCKER_TYPE}/${CYPRESS_DOCKER_VERSION}"

  FILES=$(ls "${CYPRESS_DOCKER_VERSION}")
  for f in $FILES; do mv -v "${CYPRESS_DOCKER_VERSION}/${f}" jenkins/ ; done

  rm -r "${CYPRESS_DOCKER_VERSION}"
  sed -i "/ENTRYPOINT*/d" jenkins/Dockerfile
  echo 'ENTRYPOINT ["bash", "jenkins/cypress.sh"]' >>  jenkins/Dockerfile
  tail -n 1 jenkins/Dockerfile
  mv jenkins/Dockerfile{,.ci}

}

rancher_init () {
  RANCHER_HOST=$1
  SERVER_URL="https://$2"
  new_password="$3"

  # Get the admin token using the initial bootstrap password
  rancher_token=`curl -s -k -X POST "https://${RANCHER_HOST}/v3-public/localProviders/local?action=login" \
    -H "Content-Type: application/json" \
    -d '{"username":"admin","password": "password"}' | grep -o '"token":"[^"]*' | grep -o '[^"]*$'`
  echo "TOKEN: ${rancher_token}"

  # Get the correct URL to set newPassword
  PASSWORD_URL=`curl -s -k -X GET "https://${RANCHER_HOST}/v3/users?username=admin" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${rancher_token}" |  grep -o '"setpassword":"[^"]*' | grep -o '[^"]*$'`
  echo "PASSWORD_URL: ${PASSWORD_URL}"

  # Set the new password
  PASSWORD_PAYLOAD="{\"newPassword\": \"${new_password}\"}"
  curl -s -k -X POST "${PASSWORD_URL}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${rancher_token}" \
    -d "${PASSWORD_PAYLOAD}"

  # After the above. Rancher will show the login page 
  # but the server-url setting will be empty.
  # This will configure the server-url
  curl -s -k -X PUT "https://${RANCHER_HOST}/v3/settings/server-url" \
    -H "Authorization: Bearer ${rancher_token}" \
    -H 'Content-Type: application/json' \
    --data-binary "{\"name\": \"server-url\", \"value\":\"${SERVER_URL}\"}"
}


run () {
  sudo chown -R $(whoami) .
  cd dashboard
  echo "${PWD}"

  export PATH="${NODE_PATH}/node-${NODEJS_VERSION}-linux-x64/bin:${PATH}"
  export TEST_INSTRUMENT=true
  ./scripts/build-e2e

  DIR="${HOME}/dashboard"
  sudo chown -R $(whoami) .

  DASHBOARD_DIST=${DIR}/dist
  EMBER_DIST=${DIR}/dist_ember
  echo "${DASHBOARD_DIST}"
  echo "${EMBER_DIST}"

  docker run  --privileged -d -p 80:80 -p 443:443 \
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
  
  rancher_init ${RANCHER_CONTAINER_IP_FROM_HOST} ${RANCHER_NODE_EXTERNAL_IP} "password"

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
    -e TEST_SKIP_SETUP=true \
    -e TEST_BASE_URL=${TEST_BASE_URL} \
    -e TEST_USERNAME=${TEST_USERNAME} \
    -e TEST_PASSWORD=${TEST_PASSWORD} \
    -e CATTLE_BOOTSTRAP_PASSWORD=${TEST_PASSWORD} \
    -v "${PWD}":/e2e \
    -w /e2e "cypress/${CYPRESS_DOCKER_TYPE}:${CYPRESS_DOCKER_VERSION}"

  sudo chown -R $(whoami) .
  jrm ./results.xml "./junit-*"
}

setup
run