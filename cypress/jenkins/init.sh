#!/usr/bin/env bash
#
# Thin wrapper: installs prerequisites, clones qa-infra-automation,
# generates vars.yaml from Jenkins environment, runs the Ansible playbook.
#
# The playbook handles everything: provision → deploy → test → report.
#
set -euo pipefail

###############################################################################
# Paths
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JENKINS_WORKSPACE="${WORKSPACE:-$(cd "${SCRIPT_DIR}/../../.." && pwd)}"
OUTPUTS_DIR="${HOME}/.qa-infra/outputs"
mkdir -p "${OUTPUTS_DIR}"

QA_INFRA_REPO="${QA_INFRA_REPO:-https://github.com/izaac/qa-infra-automation.git}"
QA_INFRA_BRANCH="${QA_INFRA_BRANCH:-dashboard_tests}"
QA_INFRA_DIR="${JENKINS_WORKSPACE}/qa-infra-automation"
PLAYBOOK_DIR="${QA_INFRA_DIR}/ansible/testing/dashboard-e2e"

# Ansible verbosity: 0=normal, 1=-v, 2=-vv, etc.
ANSIBLE_VERBOSITY="${ANSIBLE_VERBOSITY:-0}"
export ANSIBLE_NOCOWS=1

###############################################################################
# Install and verify prerequisites (Ubuntu/Debian executor)
###############################################################################
install_prerequisites() {
  echo "[init] Installing prerequisites..."

  if command -v apt-get &>/dev/null; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq jq curl unzip gnupg software-properties-common >/dev/null
  fi

  # OpenTofu
  if ! command -v tofu &>/dev/null; then
    echo "[init] Installing OpenTofu..."
    local tofu_version="1.11.5"
    local tofu_deb="tofu_${tofu_version}_amd64.deb"
    local tofu_base="https://github.com/opentofu/opentofu/releases/download/v${tofu_version}"
    curl -fsSL -o "/tmp/${tofu_deb}" "${tofu_base}/${tofu_deb}"
    curl -fsSL -o /tmp/tofu_SHA256SUMS "${tofu_base}/tofu_${tofu_version}_SHA256SUMS"
    (cd /tmp && grep "${tofu_deb}" tofu_SHA256SUMS | sha256sum -c -)
    sudo dpkg -i "/tmp/${tofu_deb}" >/dev/null
    rm -f "/tmp/${tofu_deb}" /tmp/tofu_SHA256SUMS
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
    current_ver=$(ansible-playbook --version 2>/dev/null | head -1 | grep -oP 'core \K[0-9]+\.[0-9]+' || echo "0.0")
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
      local uv_version="0.11.2"
      local uv_base="https://github.com/astral-sh/uv/releases/download/${uv_version}"
      local uv_archive="uv-x86_64-unknown-linux-gnu.tar.gz"
      local uv_tmp="/tmp/${uv_archive}"
      curl -fsSL -o "${uv_tmp}" "${uv_base}/${uv_archive}"
      curl -fsSL -o "${uv_tmp}.sha256" "${uv_base}/${uv_archive}.sha256"
      (cd /tmp && sha256sum -c "${uv_tmp}.sha256")
      mkdir -p "${HOME}/.local/bin"
      tar -xzf "${uv_tmp}" --strip-components=1 -C "${HOME}/.local/bin" \
        "uv-x86_64-unknown-linux-gnu/uv" "uv-x86_64-unknown-linux-gnu/uvx"
      rm -f "${uv_tmp}" "${uv_tmp}.sha256"
    fi
    uv tool uninstall ansible 2>/dev/null || true
    uv tool uninstall ansible-core 2>/dev/null || true
    uv tool install "ansible-core<2.17" --with ansible
  fi

  ansible-galaxy collection install cloud.terraform kubernetes.core community.docker community.crypto --force-with-deps 2>/dev/null || true

  local ansible_venv="${HOME}/.local/share/uv/tools/ansible-core"
  if [[ -d "${ansible_venv}" ]]; then
    uv pip install --python "${ansible_venv}/bin/python" kubernetes docker 2>/dev/null || true
  fi

  # kubectl
  if ! command -v kubectl &>/dev/null; then
    local kubectl_ver="${KUBECTL_VERSION:-v1.29.8}"
    curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/${kubectl_ver}/bin/linux/amd64/kubectl"
    curl -fsSL -o /tmp/kubectl.sha256 "https://dl.k8s.io/release/${kubectl_ver}/bin/linux/amd64/kubectl.sha256"
    echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum -c -
    sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
    rm -f /tmp/kubectl /tmp/kubectl.sha256
  fi

  # Helm
  if ! command -v helm &>/dev/null; then
    local helm_version="${HELM_VERSION:-3.17.3}"
    local tarfile="helm-v${helm_version}-linux-amd64.tar.gz"
    curl -fsSL -o "/tmp/${tarfile}" "https://get.helm.sh/${tarfile}"
    curl -fsSL -o "/tmp/${tarfile}.sha256sum" "https://get.helm.sh/${tarfile}.sha256sum"
    (cd /tmp && sha256sum -c "${tarfile}.sha256sum")
    sudo tar -C /usr/local/bin --strip-components=1 -xzf "/tmp/${tarfile}" linux-amd64/helm
    rm -f "/tmp/${tarfile}" "/tmp/${tarfile}.sha256sum"
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

###############################################################################
# Clone qa-infra-automation
###############################################################################
clone_qa_infra() {
  if [[ -d "${QA_INFRA_DIR}/.git" ]]; then
    echo "[init] qa-infra-automation already present, updating..."
    cd "${QA_INFRA_DIR}" && git fetch origin && git checkout "${QA_INFRA_BRANCH}" && git pull origin "${QA_INFRA_BRANCH}" || true
  else
    echo "[init] Cloning qa-infra-automation (${QA_INFRA_BRANCH})..."
    git clone -b "${QA_INFRA_BRANCH}" "${QA_INFRA_REPO}" "${QA_INFRA_DIR}"
  fi
}

###############################################################################
# Generate vars.yaml from Jenkins environment variables
###############################################################################
generate_vars() {
  local vars_file="${PLAYBOOK_DIR}/vars.yaml"
  local prefix
  prefix="$(head -c 4 /dev/urandom | xxd -p)"

  echo "[init] prefix=${prefix}"

  cat > "${vars_file}" <<EOF
# Auto-generated from Jenkins environment — $(date -u +%Y-%m-%dT%H:%M:%SZ)

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

###############################################################################
# Run the playbook
###############################################################################
run_playbook() {
  local tags="${1:-}"
  local verbose_flags=()

  if [[ "${ANSIBLE_VERBOSITY}" -gt 0 ]]; then
    verbose_flags=("-$(printf 'v%.0s' $(seq 1 "${ANSIBLE_VERBOSITY}"))")
  fi

  cd "${PLAYBOOK_DIR}"

  echo "============================================================"
  echo " Dashboard E2E Pipeline (Ansible)"
  echo " JOB_TYPE=${JOB_TYPE:-recurring}"
  echo " RANCHER_IMAGE_TAG=${RANCHER_IMAGE_TAG:-v2.14-head}"
  echo "============================================================"

  local tag_args=()
  if [[ -n "${tags}" ]]; then
    tag_args=(--tags "${tags}")
  fi

  ANSIBLE_CONFIG="${PLAYBOOK_DIR}/ansible.cfg" \
    ansible-playbook \
      dashboard-e2e-playbook.yml \
      --extra-vars "@vars.yaml" \
      "${verbose_flags[@]}" \
      "${tag_args[@]}"
}

###############################################################################
# Destroy (called with: init.sh destroy)
###############################################################################
destroy() {
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
      --extra-vars "@vars.yaml" \
      --tags cleanup \
      "${verbose_flags[@]}" || true

  echo "[cleanup] Done."
}

###############################################################################
# MAIN
###############################################################################
if [[ "${1:-}" == "destroy" ]]; then
  destroy
else
  install_prerequisites
  clone_qa_infra
  generate_vars
  run_playbook
fi
