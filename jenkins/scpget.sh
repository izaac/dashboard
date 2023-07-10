#!/bin/bash

set -x

PRIV_KEY="${HOME}/.ssh/jenkins_ecdsa"
NODE_EXTERNAL_IP="$(./corral vars ci single_ip)"

scp -i ${PRIV_KEY} -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null "${AWS_SSH_USER}@${NODE_EXTERNAL_IP}:$1" .