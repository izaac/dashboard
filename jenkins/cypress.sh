#!/bin/bash

set -e
cd $(dirname $0)/../

pwd
ls -al

yarn install

NO_COLOR=1 cypress run --browser chrome --reporter junit --reporter-options "mochaFile=junit-[hash].xml,toConsole=true,jenkinsMode=true"
