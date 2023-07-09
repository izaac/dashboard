#!/bin/bash
shopt -s extglob
set -x

echo "======== MEMORY ======"
free -m

NODEJS_VERSION="${NODEJS_VERSION:-v14.19.1}"
NODEJS_DOWNLOAD_URL="https://nodejs.org/dist"
NODEJS_FILE="node-${NODEJS_VERSION}-linux-x64.tar.xz"
CYPRESS_DOCKER_TYPE="${CYPRESS_DOCKER_TYPE:-included}"
CYPRESS_DOCKER_VERSION="${CYPRESS_DOCKER_VERSION:-12.3.0}"
CYPRESS_DOCKER_OWNER="cypress-io"
CYPRESS_DOCKER_REPO="cypress-docker-images"
CYPRESS_DOCKER_BRANCH="${CYPRESS_DOCKER_BRANCH:-master}"
GITHUB_CODELOAD_URL="https://codeload.github.com"
GITHUB_CODELOAD_PATH="${GITHUB_CODELOAD_URL}/${CYPRESS_DOCKER_OWNER}/${CYPRESS_DOCKER_REPO}"

if [ -f "${NODEJS_FILE}" ]; then rm -r "${NODEJS_FILE}"; fi
curl -L --silent -o "${NODEJS_FILE}" \
  "${NODEJS_DOWNLOAD_URL}/${NODEJS_VERSION}/${NODEJS_FILE}"

NODE_PATH="${PWD}/nodejs"
mkdir -p ${NODE_PATH}
tar -xJf "${NODEJS_FILE}" -C ${NODE_PATH}
export PATH="${NODE_PATH}/node-${NODEJS_VERSION}-linux-x64/bin:${PATH}"
npm_config_loglevel=error

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
