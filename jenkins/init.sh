#!/bin/bash

set -e
set -x

go version

if [[ ! -d "${HOME}/.ssh" ]]; then mkdir -p "${HOME}/.ssh"; fi
PRIV_KEY="${HOME}/.ssh/jenkins_ecdsa"
if [ -f "${PRIV_KEY}" ]; then rm "${PRIV_KEY}"; fi
ssh-keygen -t ecdsa -b 521 -N "" -f "${PRIV_KEY}"

cat << EOF >> ${HOME}/.ssh/config
Host *
  ServerAliveInterval 50
EOF

cd /opt/src/github.com/rancherlabs/corral-packages/
make init
make build
echo "${PWD}"
cd ..
cat ${CATTLE_TEST_CONFIG}
env
cd $WORKSPACE
tests/v2/validation/pipeline/singlenode/singlenode.sh
singlenode

corral list

NODE_EXTERNAL_IP="$(corral vars ci single_ip)"
echo "${PWD}"

sleep 10

# UNCOMMENT THE FOLLOWING AFTER DEV TESTING

#ssh -i ${PRIV_KEY} -o StrictHostKeyChecking=no \
#  -o UserKnownHostsFile=/dev/null "${AWS_SSH_USER}@${NODE_EXTERNAL_IP}" "git clone -b ${DASHBOARD_BRANCH} ${GITHUB_URL}${DASHBOARD_REPO} /home/{${AWS_SSH_USER}/dashboard"

# temporary to work with local dev
scp -r -i ${PRIV_KEY} -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null /opt/dashboard/ "${AWS_SSH_USER}@${NODE_EXTERNAL_IP}:/home/${AWS_SSH_USER}/dashboard"

ssh -i ${PRIV_KEY} -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null "${AWS_SSH_USER}@${NODE_EXTERNAL_IP}" "ls -al /home/${AWS_SSH_USER};"

DEBUG="${DEBUG:-false}"

DASHBOARD="/home/${AWS_SSH_USER}/dashboard"
NODEJS_VERSION="${NODEJS_VERSION:-v14.19.1}"
NODEJS_FILE="node-${NODEJS_VERSION}-linux-x64.tar.xz"
CYPRESS_DOCKER_TYPE="${CYPRESS_DOCKER_TYPE:-included}"
CYPRESS_DOCKER_VERSION="${CYPRESS_DOCKER_VERSION:-12.3.0}"
PRIV_KEY="${HOME}/.ssh/jenkins_ecdsa"
export RANCHER_NODE_EXTERNAL_IP="${NODE_EXTERNAL_IP}"

env | egrep '^(DASHBOARD|CORRAL_|CYPRESS_|AWS_|NODEJS_|GITHUB_|RANCHER_|REPO|BRANCH|DEBUG).*\=.+' | sort >> .env

if [ "false" != "${DEBUG}" ]; then
    cat .env
fi

cat .env

sed -i 's/^/export /' .env

cat .env

scp -i ${PRIV_KEY} -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null .env "${AWS_SSH_USER}@${RANCHER_NODE_EXTERNAL_IP}:/home/${AWS_SSH_USER}/.env"
