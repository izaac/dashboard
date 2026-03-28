#!/bin/bash

shopt -s extglob
set -e

# Source the local configuration file to generate .env
source cypress/jenkins/configure.sh

###############################################################################
# Pinned versions — keep in sync with cypress-io/cypress-docker-images factory
# https://github.com/cypress-io/cypress-docker-images/blob/master/factory/.env
###############################################################################
NODEJS_VERSION="${NODEJS_VERSION:-24.14.0}"
NODEJS_DOWNLOAD_URL="https://nodejs.org/dist"
NODEJS_FILE="node-v${NODEJS_VERSION}-linux-x64.tar.xz"
YARN_VERSION="${YARN_VERSION:-1.22.22}"
CYPRESS_VERSION="${CYPRESS_VERSION:-11.1.0}"
CHROME_VERSION="${CHROME_VERSION:-146.0.7680.164-1}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.29.8}"
GITHUB_URL="https://github.com/"
DASHBOARD_REPO="${DASHBOARD_REPO:-rancher/dashboard}"

exit_code=0

###############################################################################
# Install Node.js early so we can use TypeScript scripts before Docker build
###############################################################################
install_node() {
	if command -v node &>/dev/null; then
		echo "[install_node] Node.js already available: $(node --version)"
		return 0
	fi

	echo "[install_node] Installing Node.js ${NODEJS_VERSION}..."
	if [ -f "${HOME}/${NODEJS_FILE}" ]; then rm -f "${HOME}/${NODEJS_FILE}"; fi
	curl -L --silent -o "${HOME}/${NODEJS_FILE}" \
		"${NODEJS_DOWNLOAD_URL}/v${NODEJS_VERSION}/${NODEJS_FILE}"

	NODE_INSTALL_DIR="${HOME}/nodejs"
	mkdir -p "${NODE_INSTALL_DIR}"
	tar -xJf "${HOME}/${NODEJS_FILE}" -C "${NODE_INSTALL_DIR}"
	export PATH="${NODE_INSTALL_DIR}/node-v${NODEJS_VERSION}-linux-x64/bin:${PATH}"
	echo "[install_node] Installed: $(node --version)"
}

install_node

wait_for_dashboard_ui() {
	local host=$1
	local max_attempts=${2:-30}
	local url="https://${host}/dashboard/auth/login"
	echo "[wait_for_dashboard_ui] Polling ${url} (max ${max_attempts} attempts)..."
	for i in $(seq 1 "${max_attempts}"); do
		http_code=$(curl -s -k -o /dev/null -w "%{http_code}" "${url}" 2>/dev/null) || true
		if [ "${http_code}" = "200" ]; then
			echo "[wait_for_dashboard_ui] Dashboard UI is ready (attempt ${i}/${max_attempts})"
			return 0
		fi
		echo "[wait_for_dashboard_ui] attempt ${i}/${max_attempts} - HTTP ${http_code}, retrying in 10s..."
		sleep 10
	done
	echo "[wait_for_dashboard_ui] WARNING: Dashboard UI not ready after ${max_attempts} attempts"
	return 1
}

build_image() {
	target_branch=$1

	# Get target branch based on the rancher image tag
	if [[ "${RANCHER_IMAGE_TAG:-}" == "head" ]]; then
		target_branch="master"
	elif [[ "${RANCHER_IMAGE_TAG:-}" =~ ^v([0-9]+\.[0-9]+)-head$ ]]; then
		# Extract version number from the rancher image tag (e.g., v2.12-head -> 2.12)
		version_number="${BASH_REMATCH[1]}"
		target_branch="release-${version_number}"
	fi

	echo "Cloning ${target_branch}$([ "${target_branch}" != "master" ] && echo ', overlaying CI from master')"

	sudo rm -rf "${HOME}"/dashboard
	git clone -b "${target_branch}" \
		"${GITHUB_URL}${DASHBOARD_REPO}" "${HOME}"/dashboard

	cd "${HOME}"/dashboard
	if [ "${target_branch}" != "master" ]; then
		echo "Overlaying cypress/jenkins and dependencies from master onto ${target_branch}"
		git fetch origin master
		git checkout origin/master -- cypress/jenkins cypress/support package.json yarn.lock cypress.config.ts || true
	fi
	cd "${HOME}"

	shopt -s nocasematch
	if [[ -z "${IMPORTED_KUBECONFIG:-}" ]]; then
		echo "No imported kubeconfig provided"
		cd "${HOME}"
		ENTRYPOINT_FILE_PATH="dashboard/cypress/jenkins"
		sed -i.bak "/kubectl/d" "${ENTRYPOINT_FILE_PATH}/cypress.sh"
		sed -i.bak "/imported_config/d" "${ENTRYPOINT_FILE_PATH}/Dockerfile.ci"
	else
		echo "Imported kubeconfig found, preparing file"
		echo "${IMPORTED_KUBECONFIG}" | base64 -d >"${HOME}"/dashboard/imported_config
	fi
	shopt -u nocasematch

	# Node.js is already installed by install_node() — just ensure yarn is available
	npm install -g yarn@"${YARN_VERSION}" --silent 2>/dev/null

	cd "${HOME}"/dashboard
	yarn config set ignore-engines true --silent

	yarn cache clean 2>/dev/null || true
	yarn install --frozen-lockfile

	# Verify critical dependency
	if [ -d "node_modules/cypress-multi-reporters" ]; then
		echo "Reporter found in dashboard/node_modules"
	else
		echo "ERROR: Reporter NOT found in dashboard/node_modules"
		for module_path in node_modules/*cypress*; do
			[ -e "${module_path}" ] || continue
			basename "${module_path}"
		done
	fi

	cd "${HOME}"

	ENTRYPOINT_FILE_PATH="dashboard/cypress/jenkins"
	sed -i "s/CYPRESSTAGS/${CYPRESS_TAGS:-}/g" ${ENTRYPOINT_FILE_PATH}/cypress.sh

	docker build --quiet -f "${ENTRYPOINT_FILE_PATH}/Dockerfile.ci" \
		--build-arg YARN_VERSION="${YARN_VERSION}" \
		--build-arg NODE_VERSION="${NODEJS_VERSION}" \
		--build-arg CYPRESS_VERSION="${CYPRESS_VERSION}" \
		--build-arg CHROME_VERSION="${CHROME_VERSION}" \
		--build-arg KUBECTL_VERSION="${KUBECTL_VERSION}" \
		-t dashboard-test .

	cd "${HOME}"/dashboard
	sudo chown -R "$(whoami)" .
}

rancher_init() {
	local rancher_host=$1
	local rancher_password="$3"

	echo "[rancher_init] Running rancher-setup.ts..."
	local setup_output
	setup_output=$(node --experimental-strip-types cypress/jenkins/rancher-setup.ts \
		--host "${rancher_host}" \
		--password "${rancher_password}" \
		--rancher-password "${RANCHER_PASSWORD:-password}")

	# Parse output: BRANCH_FROM_RANCHER=<branch>
	branch_from_rancher=$(echo "${setup_output}" | grep '^BRANCH_FROM_RANCHER=' | cut -d= -f2-)
	echo "[rancher_init] branch_from_rancher=${branch_from_rancher}"
}

DOCKER_NAME_ARG=()
if [ -n "${RANCHER_HOST:-}" ]; then
	DOCKER_NAME_ARG=(--name "${RANCHER_HOST}")
fi

if [ "${RANCHER_TYPE:-existing}" = "existing" ]; then
	wait_for_dashboard_ui "${RANCHER_HOST:-}"
	build_image "${BRANCH:-${DASHBOARD_BRANCH:-master}}"  # TODO: remove DASHBOARD_BRANCH fallback after job YAML update
	docker run --rm "${DOCKER_NAME_ARG[@]}" --env-file "${HOME}/.env" -e NODE_PATH= -t \
		-v "${HOME}":/e2e \
		-w /e2e dashboard-test || exit_code=$?
elif [ "${RANCHER_TYPE:-existing}" = "recurring" ]; then
	rancher_init "${RANCHER_HOST:-}" "${RANCHER_HOST:-}" "${RANCHER_PASSWORD:-password}"
	wait_for_dashboard_ui "${RANCHER_HOST:-}"
	build_image "${branch_from_rancher}"
	case "${CYPRESS_TAGS:-}" in
	*"@standardUser"*)
		sed -i.bak '/TEST_USERNAME/d' "${HOME}/.env"
		echo TEST_USERNAME="standard_user" >>"${HOME}/.env"
		;;
	esac
	docker run --rm "${DOCKER_NAME_ARG[@]}" --env-file "${HOME}/.env" -e NODE_PATH= -t \
		-v "${HOME}":/e2e \
		-w /e2e dashboard-test || exit_code=$?
fi

cd "${HOME}/dashboard" || { echo "WARNING: ${HOME}/dashboard not found, skipping results merge"; exit ${exit_code}; }
./node_modules/.bin/jrm "${HOME}/dashboard/results.xml" "cypress/jenkins/reports/junit/junit-*" || true

if [ -s "${HOME}/dashboard/results.xml" ]; then
	echo "cypress_exit_code=${exit_code}"
	echo "cypress_completed=completed"
fi
exit ${exit_code}
