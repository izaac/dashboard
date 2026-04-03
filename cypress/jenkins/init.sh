#!/usr/bin/env bash
#
# Thin wrapper: clones qa-infra-automation, builds the runner image,
# generates vars.yaml from Jenkins environment, runs the playbook in a container.
#
# No tool installation needed — everything is inside the container image.
#
set -euo pipefail
trap 'echo "FAILED at line $LINENO: $BASH_COMMAND (exit $?)"' ERR

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JENKINS_WORKSPACE="${WORKSPACE:-$(cd "${SCRIPT_DIR}/../../.." && pwd)}"

QA_INFRA_REPO="${QA_INFRA_REPO:-https://github.com/izaac/qa-infra-automation.git}"
QA_INFRA_BRANCH="${QA_INFRA_BRANCH:-dashboard_tests}"
QA_INFRA_DIR="${JENKINS_WORKSPACE}/qa-infra-automation"
PLAYBOOK_DIR="${QA_INFRA_DIR}/ansible/testing/dashboard-e2e"
RUNNER_IMAGE="dashboard-e2e-runner"

# Ansible verbosity: 0=normal, 1=-v, 2=-vv, etc.
ANSIBLE_VERBOSITY="${ANSIBLE_VERBOSITY:-0}"

# Clone qa-infra-automation
clone_qa_infra() {
  if [[ -d "${QA_INFRA_DIR}/.git" ]]; then
    echo "[init] qa-infra-automation already present, updating..."
    cd "${QA_INFRA_DIR}"
    if ! git fetch origin || ! git checkout -qf "${QA_INFRA_BRANCH}" || ! git reset --hard "origin/${QA_INFRA_BRANCH}"; then
      echo "[init] ERROR: Failed to update qa-infra-automation to branch '${QA_INFRA_BRANCH}'"
      exit 1
    fi
  else
    echo "[init] Cloning qa-infra-automation (${QA_INFRA_BRANCH})..."
    git clone -b "${QA_INFRA_BRANCH}" "${QA_INFRA_REPO}" "${QA_INFRA_DIR}"
  fi
}

# Build the runner image from Dockerfile.quickstart
build_runner_image() {
  echo "[init] Building ${RUNNER_IMAGE} image..."
  docker build -q -f "${PLAYBOOK_DIR}/Dockerfile.quickstart" \
    -t "${RUNNER_IMAGE}" "${PLAYBOOK_DIR}"
}

# Generate vars.yaml from Jenkins environment variables
generate_vars() {
  local vars_file="${PLAYBOOK_DIR}/vars.yaml"

  # If VARS_YAML_CONFIG is provided (Jenkins text area parameter),
  # write it directly — no need for individual env vars.
  if [[ -n "${VARS_YAML_CONFIG:-}" ]]; then
    printf '%s\n' "${VARS_YAML_CONFIG}" > "${vars_file}"

    # The playbook reads AWS infra values via env lookups; export them from the config
    # so the playbook's env-based vars pick them up.
    for var in aws_ami aws_route53_zone aws_vpc aws_subnet aws_security_group; do
      local val
      val=$(grep "^${var}:" "${vars_file}" | head -1 | sed "s/^${var}:[[:space:]]*//" | tr -d "\"'")
      if [[ -n "${val}" ]]; then
        declare -x "$(echo "${var}" | tr '[:lower:]' '[:upper:]')=${val}"
      fi
    done

    # Inject credentials from Jenkins env that the user shouldn't put in the text area
    yaml_escape() { echo "${1//\'/\'\'}"; }
    {
      echo ""
      echo "# Credentials injected from Jenkins environment"
      [[ -n "${QASE_AUTOMATION_TOKEN:-}" ]]    && echo "qase_token: '$(yaml_escape "${QASE_AUTOMATION_TOKEN}")'"
      [[ -n "${PERCY_TOKEN:-}" ]]              && echo "percy_token: '$(yaml_escape "${PERCY_TOKEN}")'"
      [[ -n "${AZURE_CLIENT_ID:-}" ]]          && echo "azure_client_id: '$(yaml_escape "${AZURE_CLIENT_ID}")'"
      [[ -n "${AZURE_CLIENT_SECRET:-}" ]]      && echo "azure_client_secret: '$(yaml_escape "${AZURE_CLIENT_SECRET}")'"
      [[ -n "${AZURE_AKS_SUBSCRIPTION_ID:-}" ]] && echo "azure_subscription_id: '$(yaml_escape "${AZURE_AKS_SUBSCRIPTION_ID}")'"
      [[ -n "${GKE_SERVICE_ACCOUNT:-}" ]]      && echo "gke_service_account: '$(yaml_escape "${GKE_SERVICE_ACCOUNT}")'"
    } >> "${vars_file}"

    export PREFIX="${PREFIX:-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')}"
    echo "[init] prefix=${PREFIX}"
    echo "[init] Wrote vars.yaml from VARS_YAML_CONFIG parameter"
    return
  fi

  local prefix
  prefix="$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
  echo "[init] prefix=${prefix}"

  cat > "${vars_file}" <<VARSEOF
# WARNING: Auto-generated from Jenkins environment — $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains secrets — do NOT commit.

# AWS
aws_region: '${AWS_REGION:-us-west-1}'
aws_ssh_user: '${AWS_SSH_USER:-ubuntu}'
aws_instance_type: '${AWS_INSTANCE_TYPE:-t3a.xlarge}'
aws_volume_size: ${AWS_VOLUME_SIZE:-${VOLUME_SIZE:-60}}
aws_volume_type: '${AWS_VOLUME_TYPE:-gp3}'

# K3s
k3s_kubernetes_version: '${K3S_KUBERNETES_VERSION:-v1.30.0+k3s1}'
server_count: ${SERVER_COUNT:-3}

# Rancher
rancher_helm_repo: '${RANCHER_HELM_REPO:-rancher-com-rc}'
rancher_image_tag: '${RANCHER_IMAGE_TAG:-v2.14-head}'
cert_manager_version: '${CERT_MANAGER_VERSION:-1.11.0}'
bootstrap_password: '${BOOTSTRAP_PASSWORD:-password}'
rancher_password: '${RANCHER_PASSWORD:-password1234}'
rancher_username: '${RANCHER_USERNAME:-admin}'
rancher_host: '${RANCHER_HOST:-}'

# Pinned versions — https://github.com/cypress-io/cypress-docker-images/blob/master/factory/.env
cypress_version: '${CYPRESS_VERSION:-11.1.0}'
nodejs_version: '${NODEJS_VERSION:-24.14.0}'
yarn_version: '${YARN_VERSION:-1.22.22}'
chrome_version: '${CHROME_VERSION:-146.0.7680.164-1}'
kubectl_version: '${KUBECTL_VERSION:-v1.29.8}'

# Dashboard
dashboard_repo: '${DASHBOARD_REPO:-rancher/dashboard}'
dashboard_branch: '${DASHBOARD_BRANCH:-${BRANCH:-master}}'

# Cypress
cypress_tags: '${CYPRESS_TAGS:-@adminUser}'
job_type: '${JOB_TYPE:-recurring}'
create_initial_clusters: ${CREATE_INITIAL_CLUSTERS:-true}

# Reporting
percy_enabled: false
qase_enabled: ${QASE_REPORT:-false}
qase_project: '${QASE_PROJECT:-SANDBOX}'

# Credentials (from env, but make them available as vars too)
percy_token: '${PERCY_TOKEN:-}'
qase_token: '${QASE_AUTOMATION_TOKEN:-}'
azure_client_id: '${AZURE_CLIENT_ID:-}'
azure_client_secret: '${AZURE_CLIENT_SECRET:-}'
azure_subscription_id: '${AZURE_AKS_SUBSCRIPTION_ID:-}'
gke_service_account: '${GKE_SERVICE_ACCOUNT:-}'
VARSEOF

  export PREFIX="${prefix}"
  echo "[init] Generated ${vars_file}"
}

# Run the playbook inside the runner container
run_container() {
  local tags="${1:-}"
  local skip_tags="${2:-}"

  local verbose_flags=()
  if [[ "${ANSIBLE_VERBOSITY}" -gt 0 ]]; then
    verbose_flags=("-$(printf 'v%.0s' $(seq 1 "${ANSIBLE_VERBOSITY}"))")
  fi

  local tag_args=()
  if [[ -n "${tags}" ]]; then
    tag_args=(--tags "${tags}")
  fi

  local skip_args=()
  if [[ -n "${skip_tags}" ]]; then
    skip_args=(--skip-tags "${skip_tags}")
  fi

  local vars_file="${PLAYBOOK_DIR}/vars.yaml"
  local yaml_image_tag yaml_job_type
  yaml_image_tag=$(grep '^rancher_image_tag:' "${vars_file}" 2>/dev/null | head -1 | sed 's/^rancher_image_tag:[[:space:]]*//' | tr -d "\"'")
  yaml_job_type=$(grep '^job_type:' "${vars_file}" 2>/dev/null | head -1 | sed 's/^job_type:[[:space:]]*//' | tr -d "\"'")

  echo "============================================================"
  echo " Dashboard E2E Pipeline (Containerized)"
  echo " job_type=${yaml_job_type:-recurring}"
  echo " rancher_image_tag=${yaml_image_tag:-v2.14-head}"
  echo "============================================================"

  echo "[init] ansible-playbook args: ${verbose_flags[*]:-} ${tag_args[*]:-} ${skip_args[*]:-}"

  docker run --rm -t \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${PLAYBOOK_DIR}:/playbook" \
    -v "${QA_INFRA_DIR}:/qa-infra" \
    -e QA_INFRA_DIR=/qa-infra \
    -e HOST_DASHBOARD_DIR="${PLAYBOOK_DIR}/dashboard" \
    -e AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}" \
    -e AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}" \
    -e PREFIX="${PREFIX:-}" \
    "${RUNNER_IMAGE}" \
    "${verbose_flags[@]}" \
    "${tag_args[@]}" \
    "${skip_args[@]}"
}

# --- Main ---
if [[ "${1:-}" == "destroy" ]]; then
  clone_qa_infra
  build_runner_image

  if [[ ! -f "${PLAYBOOK_DIR}/vars.yaml" ]]; then
    echo "[cleanup] No vars.yaml found — nothing to destroy"
    exit 0
  fi

  echo "[cleanup] Destroying infrastructure via playbook..."
  run_container "cleanup,never" "" || true
  echo "[cleanup] Done."
else
  clone_qa_infra
  build_runner_image
  generate_vars

  # Validate vars.yaml has required keys
  vars_file="${PLAYBOOK_DIR}/vars.yaml"
  for key in rancher_image_tag cypress_tags job_type; do
    if ! grep -q "^${key}:" "${vars_file}"; then
      echo "[init] ERROR: vars.yaml is missing required key '${key}'"
      exit 1
    fi
  done

  # Run playbook: provision + setup (skip test — Docker run is below for streaming)
  run_container "" "test"

  # Run Cypress in Docker directly for real-time log streaming in Jenkins
  echo "[init] Running Cypress tests (docker)..."

  if ! docker image inspect dashboard-test:latest &>/dev/null; then
    echo "[init] ERROR: dashboard-test:latest image not found — playbook build may have failed"
    exit 1
  fi
  if [[ ! -f "${PLAYBOOK_DIR}/.env" ]]; then
    echo "[init] ERROR: .env not found — playbook setup may have failed"
    exit 1
  fi

  # Sanitize container name
  container_name="cypress-$(echo "${RANCHER_HOST:-dashboard-e2e}" | sed 's/[^a-zA-Z0-9_.-]/-/g')"
  docker rm -f "${container_name}" 2>/dev/null || true

  cypress_exit=0
  docker run --rm -t \
    --name "${container_name}" \
    --shm-size=2g \
    --env-file "${PLAYBOOK_DIR}/.env" \
    -e NODE_PATH="" \
    -v "${PLAYBOOK_DIR}/dashboard:/e2e" \
    -w /e2e \
    dashboard-test:latest || cypress_exit=$?

  echo "[init] Cypress exited with code ${cypress_exit}"

  # Copy results to workspace for Jenkins artifact collection
  dashboard_dir="${PLAYBOOK_DIR}/dashboard"
  cp "${dashboard_dir}/results.xml" "${JENKINS_WORKSPACE}/" 2>/dev/null || true
  mkdir -p "${JENKINS_WORKSPACE}/html"
  cp -r "${dashboard_dir}/cypress/reports/html/"* "${JENKINS_WORKSPACE}/html/" 2>/dev/null || true

  exit "${cypress_exit}"
fi
