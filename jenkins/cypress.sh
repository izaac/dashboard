#!/bin/bash

set -e
cd $(dirname $0)/../

pwd
ls -al

yarn install

NOCOLOR=1 cypress run --browser chrome --reporter junit --reporter-options "mochaFile=junit-[hash].xml,toConsole=true,jenkins/sandbox/cypress.sh"
