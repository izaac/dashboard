set -x
set -eu

DEBUG="${DEBUG:-false}"

env | egrep '^(CORRAL_|CYPRESS_|AWS_|NODEJS_|GITHUB_|RANCHER_|REPO|BRANCH).*\=.+' | sort > .env

if [ "false" != "${DEBUG}" ]; then
    cat .env
fi

PRIV_KEY="${HOME}/.ssh/jenkins_ecdsa"
NODE_EXTERNAL_IP="$(corral vars ci single_ip)"
scp -i ${PRIV_KEY} -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null .env "${AWS_SSH_USER}@${NODE_EXTERNAL_IP}:/home/${AWS_SSH_USER}"