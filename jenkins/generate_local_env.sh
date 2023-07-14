set -x
set -eu

DEBUG="${DEBUG:-false}"

env | egrep '^(DASHBOARD|CORRAL_|CYPRESS_|AWS_|NODEJS_|GITHUB_|RANCHER_|REPO|BRANCH).*\=.+' | sort > .env

if [ "false" != "${DEBUG}" ]; then
    cat .env
fi
