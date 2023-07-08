#!/bin/bash

RANCHER_CONTAINER_NAME="${RANCHER_CONTAINER_NAME:-rancher}"
CYPRESS_CONTAINER_NAME="${CYPRESS_CONTAINER_NAME:-cye2e}"

rancherRunning=$( docker inspect -f '{{.State.Running}}' ${RANCHER_CONTAINER_NAME} 2>/dev/null )
rancherImageExist=$( docker inspect -f '{{.Config.Image}}' ${RANCHER_CONTAINER_NAME} 2>/dev/null )
cypressRunning=$( docker inspect -f '{{.State.Running}}' ${CYPRESS_CONTAINER_NAME} 2>/dev/null )
cypressImageExist=$( docker inspect -f '{{.Config.Image}}' ${CYPRESS_CONTAINER_NAME} 2>/dev/null )

if [[ -n "${rancherRunning}" ]]; then
    echo 'Rancher is Running. Stopping.'
    docker stop ${RANCHER_CONTAINER_NAME}
fi
if [[ -n "${rancherImageExist}" ]]; then
    echo 'Rancher is not running. Remove container'
    docker rm ${RANCHER_CONTAINER_NAME}
    docker images -a | grep "rancher/rancher" | awk '{print $3}' | xargs docker rmi
fi
if [[ -n "${cypressImageRunning}" ]]; then
    echo 'Cypress is Running. Stopping.'
    docker stop ${CYPRESS_CONTAINER_NAME}
fi
if [[ -n "${cypressImageExist}" ]]; then
    echo 'Cypress is Running. Stopping.'
    docker rm ${CYPRESS_CONTAINER_NAME}
    docker images -a | grep "cypress/included" | awk '{print $3}' | xargs docker rmi
    docker images -a | grep "cypress/browsers" | awk '{print $3}' | xargs docker rmi
fi
