#!/bin/bash

set -e
set -x

OS="$(uname -s)"
case "${OS}" in
    Linux*)     MACHINE=amd64;;
    Darwin*)    MACHINE=darwin-amd64;;
esac

case "${MACHINE}" in
 amd64*)        GOLANG_PGK_SUFFIX=linux-amd64 ;;
 darwin-amd64*) GOLANG_PGK_SUFFIX=darwin-amd64 ;;
esac

GO_DL_URL="https://go.dev/dl" 
GO_DL_VERSION="${GO_DL_VERSION-1.20.5}"
GO_PKG_FILENAME="go${GO_DL_VERSION}.${GOLANG_PGK_SUFFIX}.tar.gz"
GO_DL_PACKAGE="${GO_DL_URL}/${GO_PKG_FILENAME}"
CORRAL_PATH="."
CORRAL="${CORRAL_PATH}/corral"
CORRAL_VERSION="${CORRAL_VERSION:-1.1.1}"
CORRAL_DOWNLOAD_URL="https://github.com/rancherlabs/corral/releases/download/"
CORRAL_DOWNLOAD_BIN="${CORRAL_DOWNLOAD_URL}v${CORRAL_VERSION}/corral-${CORRAL_VERSION}-${MACHINE}"
PATH="${CORRAL_PATH}:${PATH}"
CORRAL_PACKAGES_REPO="${CORRAL_PACKAGES_REPO:-https://github.com/rancherlabs/corral-packages.git}"
CORRAL_PACKAGES_BRANCH="${CORRAL_PACKAGES_BRANCH:-main}"
REPO="${REPO:-https://github.com/rancher/dashboard.git}"
BRANCH="${BRANCH:-master}"

if [ -f "${CORRAL}" ]; then rm "${CORRAL}"; fi
curl -L --silent -o "${CORRAL}" "${CORRAL_DOWNLOAD_BIN}"
chmod +x "${CORRAL}"
curl -L --silent -o "${GO_PKG_FILENAME}" "${GO_DL_PACKAGE}"
tar -C "${HOME}" -xzf "${GO_PKG_FILENAME}"

ls -al "${HOME}"
export PATH=$PATH:"${HOME}/go/bin:${HOME}/bin"

go version
./corral version

if [[ ! -d "${HOME}/.ssh" ]]; then mkdir -p "${HOME}/.ssh"; fi
PRIV_KEY="${HOME}/.ssh/jenkins_ecdsa"
if [ -f "${PRIV_KEY}" ]; then rm "${PRIV_KEY}"; fi
ssh-keygen -t ecdsa -b 521 -N "" -f "${PRIV_KEY}"

./corral config --public_key "${HOME}/.ssh/jenkins_ecdsa.pub" --user_id jenkins
./corral config vars set corral_user_public_key "$(cat ${HOME}/.ssh/jenkins_ecdsa.pub)"
./corral config vars set corral_user_id jenkins
./corral config vars set aws_ssh_user ${AWS_SSH_USER}
./corral config vars set aws_access_key ${AWS_ACCESS_KEY_ID}
./corral config vars set aws_secret_key ${AWS_SECRET_ACCESS_KEY}
./corral config vars set aws_ami ${AWS_AMI}
./corral config vars set aws_region ${AWS_REGION}
./corral config vars set aws_security_group ${AWS_SECURITY_GROUP}
./corral config vars set aws_subnet ${AWS_SUBNET}
./corral config vars set aws_vpc ${AWS_VPC}
./corral config vars set volume_type ${AWS_VOLUME_TYPE}
./corral config vars set volume_iops ${AWS_VOLUME_IOPS}

cd corral-packages
make init
make build
echo "${PWD}"
cd ..
./corral create --recreate --debug ci corral-packages/dist/aws-t3a.2xlarge
NODE_EXTERNAL_IP="$(./corral vars ci single_ip)"
cd ..
echo "${PWD}"

sleep 10
ssh -i ${PRIV_KEY} -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null "${AWS_SSH_USER}@${NODE_EXTERNAL_IP}" \
    "git clone -b ${BRANCH} ${REPO} && git clone -b ${CORRAL_PACKAGES_BRANCH} ${CORRAL_PACKAGES_REPO}"
