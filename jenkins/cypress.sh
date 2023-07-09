#!/bin/bash

set -e
cd $(dirname $0)/../

pwd
ls -al

yarn install

cypress run --browser chrome --reporter junit --reporter-options "mochaFile=junit-[hash].xml,toConsole=true"
ls -al
ls -al dashboard
ls -al dashboard/cypress