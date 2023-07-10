#!/bin/bash

set -x

PRIV_KEY="${HOME}/.ssh/jenkins_ecdsa"
NODE_EXTERNAL_IP="$(./corral vars ci single_ip)"

ssh -i ${PRIV_KEY} -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null "${AWS_SSH_USER}@${NODE_EXTERNAL_IP}" tree

scp -r -i ${PRIV_KEY} -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null "${AWS_SSH_USER}@${NODE_EXTERNAL_IP}:$1" .