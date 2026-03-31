#!/usr/bin/env bash
#
# Thin wrapper: installs prerequisites, clones qa-infra-automation,
# generates vars.yaml from Jenkins environment, runs the Ansible playbook.
#
# The playbook handles everything: provision → deploy → test → report.
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

# Ansible verbosity: 0=normal, 1=-v, 2=-vv, etc.
ANSIBLE_VERBOSITY="${ANSIBLE_VERBOSITY:-0}"
export ANSIBLE_NOCOWS=1

# Pinned binary checksums (SHA-256)
readonly TOFU_VERSION="1.11.5"
readonly TOFU_SHA256="901121681e751574d739de5208cad059eddf9bd739b575745cf9e3c961b28a13"

readonly UV_VERSION="0.11.2"
readonly UV_SHA256="7ac2ca0449c8d68dae9b99e635cd3bc9b22a4cb1de64b7c43716398447d42981"

readonly KUBECTL_VERSION="v1.29.8"
readonly KUBECTL_SHA256="038454e0d79748aab41668f44ca6e4ac8affd1895a94f592b9739a0ae2a5f06a"

readonly HELM_VERSION="3.17.3"
readonly HELM_SHA256="ee88b3c851ae6466a3de507f7be73fe94d54cbf2987cbaa3d1a3832ea331f2cd"

# Install and verify prerequisites (Ubuntu/Debian — runs as root)
install_prerequisites() {
  echo "[init] Installing prerequisites..."

  # Only run apt if core tools are missing
  if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null || ! command -v unzip &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq jq curl unzip gnupg software-properties-common >/dev/null
  fi

  # OpenTofu (statically linked Go binary)
  local installed_tofu
  installed_tofu=$(tofu --version 2>/dev/null | head -1 | sed 's/OpenTofu v//') || true
  if [[ "${installed_tofu}" != "${TOFU_VERSION}" ]]; then
    echo "[init] Installing OpenTofu ${TOFU_VERSION}..."
    local tofu_zip="tofu_${TOFU_VERSION}_linux_amd64.zip"
    curl -fsSL -o "/tmp/${tofu_zip}" \
      "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/${tofu_zip}"
    echo "${TOFU_SHA256}  /tmp/${tofu_zip}" | sha256sum -c -
    unzip -o "/tmp/${tofu_zip}" tofu -d /usr/local/bin/ >/dev/null
    chmod +x /usr/local/bin/tofu
    rm -f "/tmp/${tofu_zip}"
  fi

  if command -v tofu &>/dev/null && ! command -v terraform &>/dev/null; then
    ln -sf "$(command -v tofu)" /usr/local/bin/terraform
  fi

  export PATH="${HOME}/.local/bin:${PATH}"

  # Ansible (via uv — pin <2.17 for Python 3.8 target compatibility)
  local need_ansible=false
  if ! command -v ansible-playbook &>/dev/null; then
    need_ansible=true
  else
    local current_ver
    current_ver=$(ansible-playbook --version 2>/dev/null | head -1 | sed -n 's/.*core \([0-9]*\.[0-9]*\).*/\1/p')
    current_ver="${current_ver:-0.0}"
    local major minor
    major=$(echo "${current_ver}" | cut -d. -f1)
    minor=$(echo "${current_ver}" | cut -d. -f2)
    if [[ "${major}" -ge 2 && "${minor}" -ge 17 ]] || [[ "${major}" -ge 3 ]]; then
      need_ansible=true
    fi
  fi

  if [[ "${need_ansible}" == "true" ]]; then
    echo "[init] Installing Ansible..."
    if ! command -v uv &>/dev/null; then
      local uv_archive="uv-x86_64-unknown-linux-gnu.tar.gz"
      local uv_tmp="/tmp/${uv_archive}"
      curl -fsSL -o "${uv_tmp}" \
        "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${uv_archive}"
      echo "${UV_SHA256}  ${uv_tmp}" | sha256sum -c -
      mkdir -p "${HOME}/.local/bin"
      tar -xzf "${uv_tmp}" --strip-components=1 -C "${HOME}/.local/bin" \
        "uv-x86_64-unknown-linux-gnu/uv" "uv-x86_64-unknown-linux-gnu/uvx"
      rm -f "${uv_tmp}"
    fi
    uv tool uninstall ansible 2>/dev/null || true
    uv tool uninstall ansible-core 2>/dev/null || true
    uv tool install "ansible-core<2.17" --with ansible
  fi

  ansible-galaxy collection install cloud.terraform kubernetes.core "community.docker:<5" "community.crypto:<3" --upgrade &>/dev/null || true

  local ansible_venv="${HOME}/.local/share/uv/tools/ansible-core"
  if [[ -d "${ansible_venv}" ]]; then
    uv pip install --python "${ansible_venv}/bin/python" kubernetes docker 2>/dev/null || true
  fi

  # kubectl (statically linked Go binary)
  local installed_kubectl
  installed_kubectl=$(kubectl version --client --short 2>/dev/null | sed -n 's/.*v\([0-9.]*\).*/\1/p') || true
  installed_kubectl="${installed_kubectl:-$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' | sed 's/^v//' || true)}"
  if [[ "${installed_kubectl}" != "${KUBECTL_VERSION#v}" ]]; then
    echo "[init] Installing kubectl ${KUBECTL_VERSION}..."
    curl -fsSL -o /tmp/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    echo "${KUBECTL_SHA256}  /tmp/kubectl" | sha256sum -c -
    install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
    rm -f /tmp/kubectl
  fi

  # Helm (statically linked Go binary)
  local installed_helm
  installed_helm=$(helm version --short 2>/dev/null | sed -n 's/v\([0-9.]*\).*/\1/p') || true
  if [[ "${installed_helm}" != "${HELM_VERSION}" ]]; then
    echo "[init] Installing Helm ${HELM_VERSION}..."
    local tarfile="helm-v${HELM_VERSION}-linux-amd64.tar.gz"
    curl -fsSL -o "/tmp/${tarfile}" "https://get.helm.sh/${tarfile}"
    echo "${HELM_SHA256}  /tmp/${tarfile}" | sha256sum -c -
    tar -C /usr/local/bin --strip-components=1 -xzf "/tmp/${tarfile}" linux-amd64/helm
    rm -f "/tmp/${tarfile}"
  fi

  local missing=()
  for cmd in tofu ansible-playbook jq kubectl ssh-keygen base64 curl helm docker; do
    if ! command -v "${cmd}" &>/dev/null; then
      missing+=("${cmd}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing tools after install: ${missing[*]}"
    exit 1
  fi

  echo "[init] Prerequisites OK: tofu=$(tofu --version 2>/dev/null | head -1), ansible=$(ansible-playbook --version 2>/dev/null | head -1)"
}

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
    # Escape single quotes for valid YAML
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

  cat > "${vars_file}" <<EOF
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
EOF

  # Also export PREFIX for the playbook
  export PREFIX="${prefix}"

  echo "[init] Generated ${vars_file}"
}

# Run the playbook
run_playbook() {
  local tags="${1:-}"
  local skip_tags="${2:-}"
  local verbose_flags=()

  if [[ "${ANSIBLE_VERBOSITY}" -gt 0 ]]; then
    verbose_flags=("-$(printf 'v%.0s' $(seq 1 "${ANSIBLE_VERBOSITY}"))")
  fi

  cd "${PLAYBOOK_DIR}"

  local vars_file="${WORKSPACE}/qa-infra-automation/ansible/testing/dashboard-e2e/vars.yaml"
  local yaml_image_tag yaml_job_type
  yaml_image_tag=$(grep '^rancher_image_tag:' "${vars_file}" 2>/dev/null | head -1 | sed 's/^rancher_image_tag:[[:space:]]*//' | tr -d "\"'")
  yaml_job_type=$(grep '^job_type:' "${vars_file}" 2>/dev/null | head -1 | sed 's/^job_type:[[:space:]]*//' | tr -d "\"'")

  echo "============================================================"
  echo " Dashboard E2E Pipeline (Ansible)"
  echo " job_type=${yaml_job_type:-recurring}"
  echo " rancher_image_tag=${yaml_image_tag:-v2.14-head}"
  echo "============================================================"

  local tag_args=()
  if [[ -n "${tags}" ]]; then
    tag_args=(--tags "${tags}")
  fi

  local skip_args=()
  if [[ -n "${skip_tags}" ]]; then
    skip_args=(--skip-tags "${skip_tags}")
  fi

  ANSIBLE_CONFIG="${PLAYBOOK_DIR}/ansible.cfg" \
    ansible-playbook \
      dashboard-e2e-playbook.yml \
      "${verbose_flags[@]}" \
      "${tag_args[@]}" \
      "${skip_args[@]}"
}

# Destroy (called with: init.sh destroy)
destroy() {
  export PATH="${HOME}/.local/bin:${PATH}"
  clone_qa_infra

  if [[ ! -f "${PLAYBOOK_DIR}/vars.yaml" ]]; then
    echo "[cleanup] No vars.yaml found — nothing to destroy"
    exit 0
  fi

  echo "[cleanup] Destroying infrastructure via playbook..."

  local verbose_flags=()
  if [[ "${ANSIBLE_VERBOSITY}" -gt 0 ]]; then
    verbose_flags=("-$(printf 'v%.0s' $(seq 1 "${ANSIBLE_VERBOSITY}"))")
  fi

  cd "${PLAYBOOK_DIR}"
  ANSIBLE_CONFIG="${PLAYBOOK_DIR}/ansible.cfg" \
    ansible-playbook \
      dashboard-e2e-playbook.yml \
      --tags cleanup,never \
      "${verbose_flags[@]}" || true

  echo "[cleanup] Done."
}

# --- Main ---
if [[ "${1:-}" == "destroy" ]]; then
  destroy
else
  install_prerequisites
  clone_qa_infra
  generate_vars

  # Validate vars.yaml has required keys
  vars_file="${WORKSPACE}/qa-infra-automation/ansible/testing/dashboard-e2e/vars.yaml"
  for key in rancher_image_tag cypress_tags job_type; do
    if ! grep -q "^${key}:" "${vars_file}"; then
      echo "[init] ERROR: vars.yaml is missing required key '${key}'"
      exit 1
    fi
  done

  # Run playbook: provision + setup (skip test — Docker run is below for streaming)
  run_playbook "" "test"

  # Run Cypress in Docker directly for real-time log streaming in Jenkins
  echo "[init] Running Cypress tests (docker)..."

  # Pre-flight checks
  if ! docker image inspect dashboard-test:latest &>/dev/null; then
    echo "[init] ERROR: dashboard-test:latest image not found — playbook build may have failed"
    exit 1
  fi
  if [[ ! -f "${JENKINS_WORKSPACE}/.env" ]]; then
    echo "[init] ERROR: .env not found — playbook setup may have failed"
    exit 1
  fi
  echo "[init] Docker image: $(docker image inspect dashboard-test:latest --format '{{.Id}}' | cut -c1-20)"
  echo "[init] .env lines: $(wc -l < "${JENKINS_WORKSPACE}/.env")"

  # Sanitize container name (Docker requires [a-zA-Z0-9][a-zA-Z0-9_.-]*)
  container_name="cypress-$(echo "${RANCHER_HOST:-dashboard-e2e}" | sed 's/[^a-zA-Z0-9_.-]/-/g')"

  # Remove any leftover container from a previous crashed run
  docker rm -f "${container_name}" 2>/dev/null || true

  cypress_exit=0
  docker run --rm -t \
    --name "${container_name}" \
    --shm-size=2g \
    --env-file "${JENKINS_WORKSPACE}/.env" \
    -e NODE_PATH="" \
    -v "${JENKINS_WORKSPACE}/dashboard:/e2e" \
    -w /e2e \
    dashboard-test:latest || cypress_exit=$?

  echo "[init] Cypress exited with code ${cypress_exit}"

  # Copy results to workspace (jrm report merge runs inside the Docker container)
  dashboard_dir="${JENKINS_WORKSPACE}/dashboard"
  cp "${dashboard_dir}/results.xml" "${JENKINS_WORKSPACE}/" 2>/dev/null || true
  mkdir -p "${JENKINS_WORKSPACE}/html"
  cp -r "${dashboard_dir}/cypress/reports/html/"* "${JENKINS_WORKSPACE}/html/" 2>/dev/null || true

  exit "${cypress_exit}"
fi
