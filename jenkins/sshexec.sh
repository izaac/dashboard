#!/bin/bash

set -x

PRIV_KEY="${HOME}/.ssh/jenkins_ecdsa"
source .env
ssh -v -i ${PRIV_KEY} -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null "${AWS_SSH_USER}@${RANCHER_NODE_EXTERNAL_IP}" "source .env; $1"