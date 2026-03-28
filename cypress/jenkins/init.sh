#!/usr/bin/env bash
#
# Provisions infrastructure via qa-infra-automation (tofu + ansible):
#   1. Rancher Server: k3s HA cluster + Rancher Helm install
#   2. Import Cluster: single-node k3s (for import tests)
#   3. Custom Node:    bare EC2 instance (for custom cluster tests)
#
# Prerequisites on the executor:
#   - tofu (OpenTofu), ansible-playbook, jq, kubectl, ssh-keygen, base64, curl
#   - AWS credentials as environment variables
set -euo pipefail

###############################################################################
# Paths — script lives in dashboard/cypress/jenkins/
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JENKINS_WORKSPACE="${WORKSPACE:-$(cd "${SCRIPT_DIR}/../../.." && pwd)}"
OUTPUTS_DIR="${HOME}/.qa-infra/outputs"
mkdir -p "${OUTPUTS_DIR}"

# qa-infra-automation repo (cloned at runtime)
QA_INFRA_REPO="${QA_INFRA_REPO:-https://github.com/rancher/qa-infra-automation.git}"
QA_INFRA_BRANCH="${QA_INFRA_BRANCH:-main}"
QA_INFRA_DIR="${JENKINS_WORKSPACE}/qa-infra-automation"

###############################################################################
# Install and verify prerequisites (Ubuntu/Debian executor)
###############################################################################
install_prerequisites() {
  echo "[init] Installing prerequisites..."

  # Base packages
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

  # Symlink tofu as terraform for ansible cloud.terraform plugin compatibility
  if command -v tofu &>/dev/null && ! command -v terraform &>/dev/null; then
    ln -sf "$(command -v tofu)" /usr/local/bin/terraform
  fi

  # Ensure uv tool binaries are on PATH
  export PATH="${HOME}/.local/bin:${PATH}"

  # Ansible (via uv tool — install ansible-core for entry points, with full ansible for collections)
  # Pin to <2.17 for Python 3.8 target compatibility (Ubuntu 20.04 AMI)
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
      echo "[init] ansible-core ${current_ver} too new for Python 3.8 targets, downgrading..."
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

      echo "[init] Downloading uv ${uv_version}..."
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

  # Ansible collections needed by the playbooks
  ansible-galaxy collection install cloud.terraform kubernetes.core --force-with-deps 2>/dev/null || true

  # Install Python kubernetes library into ansible's uv venv (needed by kubernetes.core modules)
  local ansible_venv="${HOME}/.local/share/uv/tools/ansible-core"
  if [[ -d "${ansible_venv}" ]]; then
    uv pip install --python "${ansible_venv}/bin/python" kubernetes 2>/dev/null || true
  fi

  # kubectl
  if ! command -v kubectl &>/dev/null; then
    echo "[init] Installing kubectl..."
    local kubectl_ver="${KUBECTL_VERSION:-v1.29.8}"
    curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/${kubectl_ver}/bin/linux/amd64/kubectl"
    curl -fsSL -o /tmp/kubectl.sha256 "https://dl.k8s.io/release/${kubectl_ver}/bin/linux/amd64/kubectl.sha256"
    echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum -c -
    sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
    rm -f /tmp/kubectl /tmp/kubectl.sha256
  fi

  # Helm (needed for version resolution)
  if ! command -v helm &>/dev/null; then
    echo "[init] Installing Helm..."
    HELM_VERSION="${HELM_VERSION:-3.17.3}"
    local tarfile="helm-v${HELM_VERSION}-linux-amd64.tar.gz"
    curl -fsSL -o "/tmp/${tarfile}" "https://get.helm.sh/${tarfile}"
    curl -fsSL -o "/tmp/${tarfile}.sha256sum" "https://get.helm.sh/${tarfile}.sha256sum"
    (cd /tmp && sha256sum -c "${tarfile}.sha256sum")
    sudo tar -C /usr/local/bin --strip-components=1 -xzf "/tmp/${tarfile}" linux-amd64/helm
    rm -f "/tmp/${tarfile}" "/tmp/${tarfile}.sha256sum"
  fi

  # Final check — all tools must be present
  local missing=()
  for cmd in tofu ansible-playbook jq kubectl ssh-keygen base64 curl helm; do
    if ! command -v "${cmd}" &>/dev/null; then
      missing+=("${cmd}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Still missing tools after install attempt: ${missing[*]}"
    exit 1
  fi

  echo "[init] Prerequisites OK: tofu=$(tofu --version 2>/dev/null | head -1), ansible=$(ansible-playbook --version 2>/dev/null | head -1)"
}

###############################################################################
# Clone qa-infra-automation
###############################################################################
clone_qa_infra() {
  if [[ -d "${QA_INFRA_DIR}/.git" ]]; then
    echo "[init] qa-infra-automation already cloned at ${QA_INFRA_DIR}"
    cd "${QA_INFRA_DIR}" && git fetch origin && git checkout "${QA_INFRA_BRANCH}" && git pull origin "${QA_INFRA_BRANCH}" || true
  else
    echo "[init] Cloning qa-infra-automation (${QA_INFRA_BRANCH})..."
    git clone -b "${QA_INFRA_BRANCH}" "${QA_INFRA_REPO}" "${QA_INFRA_DIR}"
  fi

  TOFU_MODULE="${QA_INFRA_DIR}/tofu/aws/modules/cluster_nodes"
  K3S_ANSIBLE_DIR="${QA_INFRA_DIR}/ansible/k3s/default"
  RANCHER_ANSIBLE_DIR="${QA_INFRA_DIR}/ansible/rancher/default-ha"
}

###############################################################################
# Generate a random prefix for hostname uniqueness
###############################################################################
PREFIX_RANDOM="$(head -c 4 /dev/urandom | xxd -p)"
echo "[init] prefix_random=${PREFIX_RANDOM}"

###############################################################################
# SSH key (generate ephemeral pair for this run)
###############################################################################
SSH_KEY="${OUTPUTS_DIR}/id_rsa"
if [[ ! -f "${SSH_KEY}" ]]; then
  ssh-keygen -t rsa -b 4096 -f "${SSH_KEY}" -N "" -q
  echo "[init] SSH key generated: ${SSH_KEY}"
fi

###############################################################################
# Defaults — values match config.xml Jenkins job parameters
###############################################################################
AWS_REGION="${AWS_REGION:-us-west-1}"
AWS_SSH_USER="${AWS_SSH_USER:-ubuntu}"
AWS_INSTANCE_TYPE="${AWS_INSTANCE_TYPE:-t3a.xlarge}"
AWS_VOLUME_SIZE="${AWS_VOLUME_SIZE:-${VOLUME_SIZE:-60}}"  # TODO: remove VOLUME_SIZE fallback after job YAML update
AWS_VOLUME_TYPE="${AWS_VOLUME_TYPE:-gp3}"

K3S_KUBERNETES_VERSION="${K3S_KUBERNETES_VERSION:-v1.30.0+k3s1}"
SERVER_COUNT="${SERVER_COUNT:-3}"
# TODO: remove AGENT_COUNT after job YAML update (unused)
AGENT_COUNT="${AGENT_COUNT:-0}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-1.11.0}"
BOOTSTRAP_PASSWORD="${BOOTSTRAP_PASSWORD:-password}"
RANCHER_PASSWORD="${RANCHER_PASSWORD:-password1234}"
RANCHER_USERNAME="${RANCHER_USERNAME:-admin}"

RANCHER_IMAGE_TAG="${RANCHER_IMAGE_TAG:-v2.13-head}"
RANCHER_HELM_REPO="${RANCHER_HELM_REPO:-rancher-com-rc}"
RANCHER_VERSION="${RANCHER_VERSION:-}"
RANCHER_CHART_URL=""
RANCHER_CHART_REPO=""
RANCHER_IMAGE=""
RANCHER_IMAGE_TAG_RESOLVED=""

# Ansible verbosity: 0=normal, 1=-v, 2=-vv, etc. Override with ANSIBLE_VERBOSITY env var.
ANSIBLE_VERBOSITY="${ANSIBLE_VERBOSITY:-0}"
export ANSIBLE_NOCOWS=1
ANSIBLE_VERBOSE_FLAG=""
if [[ "${ANSIBLE_VERBOSITY}" -gt 0 ]]; then
  ANSIBLE_VERBOSE_FLAG="-$(printf 'v%.0s' $(seq 1 "${ANSIBLE_VERBOSITY}"))"
fi

JOB_TYPE="${JOB_TYPE:-recurring}"
CREATE_INITIAL_CLUSTERS="${CREATE_INITIAL_CLUSTERS:-yes}"

# Test-runner vars (passed through to run.sh / Docker container)
CYPRESS_TAGS="${CYPRESS_TAGS:-@adminUser}"
CYPRESS_VERSION="${CYPRESS_VERSION:-11.1.0}"
NODEJS_VERSION="${NODEJS_VERSION:-20.17.0}"
YARN_VERSION="${YARN_VERSION:-1.22.22}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.29.8}"
CHROME_VERSION="${CHROME_VERSION:-140.0.7339.127-1}"
DASHBOARD_REPO="${DASHBOARD_REPO:-rancher/dashboard.git}"
# TODO: remove DASHBOARD_BRANCH after job YAML update — use BRANCH everywhere
DASHBOARD_BRANCH="${DASHBOARD_BRANCH:-${BRANCH:-master}}"

###############################################################################
# configure_rancher_helm — resolve chart version from helm repo
###############################################################################
configure_rancher_helm() {
  [[ -z "${RANCHER_IMAGE_TAG}" ]] && return

  case "${RANCHER_HELM_REPO}" in
    rancher-prime)
      RANCHER_CHART_URL="https://charts.rancher.com/server-charts/prime"
      RANCHER_CHART_REPO="rancher-prime"
      RANCHER_IMAGE="registry.suse.com/rancher/rancher"
      ;;
    rancher-latest)
      RANCHER_CHART_URL="https://charts.optimus.rancher.io/server-charts/latest"
      RANCHER_CHART_REPO="rancher-latest"
      RANCHER_IMAGE="stgregistry.suse.com/rancher/rancher"
      ;;
    rancher-alpha)
      RANCHER_CHART_URL="https://charts.optimus.rancher.io/server-charts/alpha"
      RANCHER_CHART_REPO="rancher-alpha"
      RANCHER_IMAGE="stgregistry.suse.com/rancher/rancher"
      ;;
    rancher-com-alpha)
      RANCHER_CHART_URL="https://releases.rancher.com/server-charts/alpha"
      RANCHER_CHART_REPO="rancher-com-alpha"
      ;;
    rancher-community)
      RANCHER_CHART_URL="https://releases.rancher.com/server-charts/stable"
      RANCHER_CHART_REPO="rancher-community"
      ;;
    *)
      RANCHER_CHART_URL="https://releases.rancher.com/server-charts/latest"
      RANCHER_CHART_REPO="rancher-com-rc"
      ;;
  esac

  helm repo add "${RANCHER_CHART_REPO}" "${RANCHER_CHART_URL}" >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1

  local version_string
  version_string=$(echo "${RANCHER_IMAGE_TAG}" | cut -f1 -d"-")

  if [[ "${RANCHER_IMAGE_TAG}" == "head" ]]; then
    RANCHER_VERSION=$(helm search repo "${RANCHER_CHART_REPO}" --devel --versions | sed -n '1!p' | head -1 | awk '{print $2}' | tr -d '[:space:]')
  elif [[ "${RANCHER_HELM_REPO}" == "rancher-alpha" ]]; then
    RANCHER_VERSION=$(helm search repo "${RANCHER_CHART_REPO}" --devel --versions | grep "^${RANCHER_CHART_REPO}/rancher[[:space:]]" | grep "${version_string}" | grep -- "-alpha" | awk '{print $2}' | sort -V | tail -1 | tr -d '[:space:]')
  elif [[ "${RANCHER_HELM_REPO}" == "rancher-latest" ]]; then
    RANCHER_VERSION=$(helm search repo "${RANCHER_CHART_REPO}" --devel --versions | grep "^${RANCHER_CHART_REPO}/rancher[[:space:]]" | grep "${version_string}" | grep -- "-rc" | awk '{print $2}' | sort -V | tail -1 | tr -d '[:space:]')
  else
    RANCHER_VERSION=$(helm search repo "${RANCHER_CHART_REPO}" --devel --versions | grep "${version_string}" | awk '{print $2}' | sort -V | tail -1 | tr -d '[:space:]')
  fi

  if [[ -z "${RANCHER_VERSION}" ]]; then
    echo "ERROR: Could not resolve Rancher version for ${RANCHER_IMAGE_TAG} in ${RANCHER_CHART_REPO}"
    exit 1
  fi

  case "${RANCHER_HELM_REPO}" in
    rancher-prime|rancher-latest|rancher-alpha)
      RANCHER_IMAGE_TAG_RESOLVED="v${RANCHER_VERSION}"
      ;;
    *)
      RANCHER_IMAGE_TAG_RESOLVED="${RANCHER_IMAGE_TAG}"
      ;;
  esac

  echo "[init] Resolved: RANCHER_VERSION=${RANCHER_VERSION}, IMAGE_TAG=${RANCHER_IMAGE_TAG_RESOLVED}, CHART_URL=${RANCHER_CHART_URL}"
}

###############################################################################
# write_tfvars — generate terraform.tfvars for cluster_nodes module
###############################################################################
write_tfvars() {
  local dest="$1"
  local hostname_prefix="$2"
  local node_count="$3"
  local roles="$4"
  local instance_type="${5:-${AWS_INSTANCE_TYPE}}"

  cat > "${dest}" <<EOF
aws_access_key      = "${AWS_ACCESS_KEY_ID}"
aws_secret_key      = "${AWS_SECRET_ACCESS_KEY}"
aws_region          = "${AWS_REGION}"
aws_ami             = "${AWS_AMI}"
aws_hostname_prefix = "${hostname_prefix}"
aws_route53_zone    = "${AWS_ROUTE53_ZONE}"
aws_ssh_user        = "${AWS_SSH_USER}"
aws_security_group  = ["${AWS_SECURITY_GROUP}"]
aws_vpc             = "${AWS_VPC}"
aws_subnet          = "${AWS_SUBNET}"
aws_volume_size     = ${AWS_VOLUME_SIZE}
aws_volume_type     = "${AWS_VOLUME_TYPE}"
instance_type       = "${instance_type}"
public_ssh_key      = "${SSH_KEY}.pub"
airgap_setup        = false
proxy_setup         = false

nodes = [
  {
    count = ${node_count}
    role  = ${roles}
  }
]
EOF
  echo "[init] Wrote tfvars: ${dest}"
}

###############################################################################
# tofu_apply — init + apply in a given workspace
###############################################################################
tofu_apply() {
  local workspace="$1"
  local tfvars_file="$2"

  cd "${TOFU_MODULE}"
  tofu init -input=false -no-color >/dev/null 2>&1 || tofu init -input=false -no-color
  tofu workspace new "${workspace}" 2>/dev/null || tofu workspace select "${workspace}"

  echo "[init] tofu apply (workspace=${workspace})..."
  if [[ "${ANSIBLE_VERBOSITY}" -gt 0 ]]; then
    tofu apply -var-file="${tfvars_file}" -auto-approve -no-color -input=false
  else
    tofu apply -var-file="${tfvars_file}" -auto-approve -no-color -input=false 2>&1 | tail -n 20
  fi
}

###############################################################################
# tofu_destroy — destroy a workspace
###############################################################################
tofu_destroy() {
  local workspace="$1"
  local tfvars_file="$2"

  cd "${TOFU_MODULE}"
  tofu workspace select "${workspace}" 2>/dev/null || return 0
  echo "[cleanup] tofu destroy (workspace=${workspace})..."
  tofu destroy -var-file="${tfvars_file}" -auto-approve -no-color -input=false 2>&1 | tail -n 5
}

###############################################################################
# generate_inventory — create static inventory from tofu state
###############################################################################
generate_inventory() {
  local workspace="$1"
  local inventory_dest="$2"
  local ssh_user="${3:-${AWS_SSH_USER}}"

  cd "${TOFU_MODULE}"
  tofu workspace select "${workspace}"

  local ips master_ip fqdn
  ips=$(tofu output -json instance_public_ips | jq -r '.[]')
  master_ip=$(tofu output -raw kube_api_host)
  fqdn=$(tofu output -raw fqdn)

  local idx=0
  local master_section=""
  local server_section=""

  for ip in ${ips}; do
    if [[ "${ip}" == "${master_ip}" ]]; then
      master_section="    master:\n      ansible_host: ${ip}\n      ansible_role: etcd,cp,worker"
    else
      idx=$((idx + 1))
      server_section="${server_section}\n    server${idx}:\n      ansible_host: ${ip}\n      ansible_role: etcd,cp,worker"
    fi
  done

  cat > "${inventory_dest}" <<EOF
master:
  hosts:
$(echo -e "${master_section}")

servers:
  hosts:$(echo -e "${server_section}")

all:
  vars:
    ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    ansible_user: ${ssh_user}
    ansible_ssh_private_key_file: ${SSH_KEY}
EOF

  echo "[init] Inventory: ${inventory_dest} (master=${master_ip}, fqdn=${fqdn})"
}

###############################################################################
# PHASE 1: Rancher Server (k3s HA + Rancher Helm)
###############################################################################
create_rancher_server() {
  echo ""
  echo "========================================="
  echo " Rancher Server Cluster"
  echo "========================================="

  local hostname_prefix="jnkui-${PREFIX_RANDOM}-rancher"

  local tfvars="${OUTPUTS_DIR}/rancher-server.tfvars"
  write_tfvars "${tfvars}" "${hostname_prefix}" "${SERVER_COUNT}" '["etcd", "cp", "worker"]'
  tofu_apply "rancher-server" "${tfvars}"

  local inventory="${OUTPUTS_DIR}/rancher-server-inventory.yml"
  generate_inventory "rancher-server" "${inventory}"

  local vars_file="${OUTPUTS_DIR}/rancher-server-k3s-vars.yaml"
  cat > "${vars_file}" <<EOF
kubernetes_version: '${K3S_KUBERNETES_VERSION}'
kubeconfig_file: '${OUTPUTS_DIR}/kubeconfig-rancher.yaml'
channel: "stable"
EOF

  echo "[init] Installing k3s on rancher server cluster..."
  cd "${QA_INFRA_DIR}"
  ANSIBLE_CONFIG="${K3S_ANSIBLE_DIR}/ansible.cfg" \
  TF_WORKSPACE="rancher-server" \
  TERRAFORM_NODE_SOURCE="tofu/aws/modules/cluster_nodes" \
    ansible-playbook \
      -i "${inventory}" \
      "${K3S_ANSIBLE_DIR}/k3s-playbook.yml" \
      --extra-vars "@${vars_file}" \
      ${ANSIBLE_VERBOSE_FLAG}

  echo "[init] k3s installed. Kubeconfig: ${OUTPUTS_DIR}/kubeconfig-rancher.yaml"

  local rancher_vars="${OUTPUTS_DIR}/rancher-server-rancher-vars.yaml"
  cat > "${rancher_vars}" <<EOF
rancher_version: '${RANCHER_VERSION}'
rancher_image_tag: '${RANCHER_IMAGE_TAG_RESOLVED:-${RANCHER_IMAGE_TAG}}'
rancher_image: '${RANCHER_IMAGE:-}'
cert_manager_version: '${CERT_MANAGER_VERSION}'
kubeconfig_file: '${OUTPUTS_DIR}/kubeconfig-rancher.yaml'
fqdn: '${RANCHER_HOST}'
bootstrap_password: '${BOOTSTRAP_PASSWORD}'
password: '${RANCHER_PASSWORD}'
rancher_chart_repo: '${RANCHER_CHART_REPO}'
rancher_chart_repo_url: '${RANCHER_CHART_URL}'
EOF

  echo "[init] Installing Rancher ${RANCHER_VERSION} on ${RANCHER_HOST}..."
  cd "${QA_INFRA_DIR}"
  ANSIBLE_CONFIG="${K3S_ANSIBLE_DIR}/ansible.cfg" \
  TF_WORKSPACE="rancher-server" \
  TERRAFORM_NODE_SOURCE="tofu/aws/modules/cluster_nodes" \
    ansible-playbook \
      "${RANCHER_ANSIBLE_DIR}/rancher-playbook.yml" \
      --extra-vars "@${rancher_vars}" \
      ${ANSIBLE_VERBOSE_FLAG}

  echo "[init] Rancher deployed at https://${RANCHER_HOST}"
}

###############################################################################
# PHASE 2: Test Clusters (import cluster + custom node)
###############################################################################
create_test_clusters() {
  echo ""
  echo "========================================="
  echo " PHASE 2: Test Clusters (parallel)"
  echo "========================================="

  # Custom Node (bare EC2 — no k3s)
  (
    echo "[init] Creating custom node..."
    local customnode_prefix="jnkui-${PREFIX_RANDOM}-ctm"
    local customnode_tfvars="${OUTPUTS_DIR}/customnode.tfvars"
    write_tfvars "${customnode_tfvars}" "${customnode_prefix}" "1" '["etcd", "cp", "worker"]' "t3a.xlarge"
    tofu_apply "customnode" "${customnode_tfvars}"

    cd "${TOFU_MODULE}"
    tofu workspace select "customnode"
    local ip
    ip=$(tofu output -raw kube_api_host)
    echo "${ip}" > "${OUTPUTS_DIR}/customnode_ip.txt"
    echo "[init] Custom node: IP=${ip}"
  ) &
  local customnode_pid=$!

  # Import Cluster (single-node k3s)
  (
    echo "[init] Creating import cluster..."
    local import_prefix="jnkui-${PREFIX_RANDOM}-imp"
    local import_tfvars="${OUTPUTS_DIR}/importcluster.tfvars"
    write_tfvars "${import_tfvars}" "${import_prefix}" "1" '["etcd", "cp", "worker"]'
    tofu_apply "importcluster" "${import_tfvars}"

    local import_inventory="${OUTPUTS_DIR}/import-inventory.yml"
    generate_inventory "importcluster" "${import_inventory}"

    local import_vars="${OUTPUTS_DIR}/import-k3s-vars.yaml"
    cat > "${import_vars}" <<EOF
kubernetes_version: '${K3S_KUBERNETES_VERSION}'
kubeconfig_file: '${OUTPUTS_DIR}/kubeconfig-import.yaml'
channel: "stable"
EOF

    echo "[init] Installing k3s on import cluster..."
    cd "${QA_INFRA_DIR}"
    ANSIBLE_CONFIG="${K3S_ANSIBLE_DIR}/ansible.cfg" \
    TF_WORKSPACE="importcluster" \
    TERRAFORM_NODE_SOURCE="tofu/aws/modules/cluster_nodes" \
      ansible-playbook \
        -i "${import_inventory}" \
        "${K3S_ANSIBLE_DIR}/k3s-playbook.yml" \
        --extra-vars "@${import_vars}" \
        ${ANSIBLE_VERBOSE_FLAG}

    echo "[init] Import cluster ready."
  ) &
  local import_pid=$!

  # Wait for both
  local fail=0
  wait "${customnode_pid}" || fail=1
  wait "${import_pid}" || fail=1
  if [[ "${fail}" -ne 0 ]]; then
    echo "ERROR: One or more test cluster provisions failed."
    exit 1
  fi

  # Note: outputs are left as files so the parent shell can read them
  # after wait (subshell variables don't propagate to parent).
  echo "[init] Test cluster provisioning complete (outputs in ${OUTPUTS_DIR})"
}

###############################################################################
# wait_for_import_cluster
###############################################################################
wait_for_import_cluster() {
  local max_attempts="${1:-12}"
  echo "[init] Waiting for import cluster API (max ${max_attempts} attempts)..."
  for i in $(seq 1 "${max_attempts}"); do
    if kubectl --kubeconfig "${OUTPUTS_DIR}/kubeconfig-import.yaml" get nodes &>/dev/null; then
      echo "[init] Import cluster API reachable (attempt ${i})"
      return 0
    fi
    echo "  attempt ${i}/${max_attempts}..."
    sleep 10
  done
  echo "[init] WARNING: import cluster API not reachable after ${max_attempts} attempts"
}

###############################################################################
# destroy_all — teardown (call with: bash init.sh destroy)
###############################################################################
destroy_all() {
  echo "[cleanup] Destroying all infrastructure..."
  for ws in rancher-server importcluster customnode; do
    local tfvars="${OUTPUTS_DIR}/${ws}.tfvars"
    [[ -f "${tfvars}" ]] && tofu_destroy "${ws}" "${tfvars}" || true
  done
  echo "[cleanup] Done."
}

###############################################################################
# MAIN
###############################################################################
main() {
  install_prerequisites

  echo "============================================================"
  echo " qa-infra-automation init.sh"
  echo " JOB_TYPE=${JOB_TYPE}, RANCHER_IMAGE_TAG=${RANCHER_IMAGE_TAG}"
  echo " PREFIX=${PREFIX_RANDOM}"
  echo "============================================================"

  # Validate required env vars
  for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_AMI AWS_ROUTE53_ZONE \
             AWS_VPC AWS_SUBNET AWS_SECURITY_GROUP; do
    if [[ -z "${!var:-}" ]]; then
      echo "ERROR: Required environment variable ${var} is not set."
      exit 1
    fi
  done

  # Clone qa-infra-automation
  clone_qa_infra

  if [[ "${JOB_TYPE}" == "recurring" ]]; then
    configure_rancher_helm

    local hostname_prefix="jnkui-${PREFIX_RANDOM}-rancher"
    RANCHER_HOST="${hostname_prefix}.${AWS_ROUTE53_ZONE}"

    shopt -s nocasematch
    local create_clusters=false
    if [[ "${CREATE_INITIAL_CLUSTERS}" != "no" ]]; then
      create_clusters=true
    fi
    shopt -u nocasematch

    # Provision all infrastructure in parallel
    echo ""
    echo "========================================="
    echo " Provisioning infrastructure (parallel)"
    echo "========================================="

    create_rancher_server &
    local rancher_pid=$!

    local test_pid=""
    if [[ "${create_clusters}" == "true" ]]; then
      create_test_clusters &
      test_pid=$!
    fi

    local fail=0
    wait "${rancher_pid}" || fail=1
    if [[ -n "${test_pid}" ]]; then
      wait "${test_pid}" || fail=1
    fi
    if [[ "${fail}" -ne 0 ]]; then
      echo "ERROR: Infrastructure provisioning failed."
      exit 1
    fi

    if [[ "${create_clusters}" == "true" ]]; then
      wait_for_import_cluster
      # Read outputs written by the subshell to files
      CUSTOM_NODE_IP=$(cat "${OUTPUTS_DIR}/customnode_ip.txt")
      CUSTOM_NODE_KEY=$(base64 -w 0 < "${SSH_KEY}")
      IMPORTED_KUBECONFIG=$(base64 -w 0 < "${OUTPUTS_DIR}/kubeconfig-import.yaml")
      echo "[init] Custom node: IP=${CUSTOM_NODE_IP}, Import cluster: kubeconfig ready"
    fi

  elif [[ "${JOB_TYPE}" == "existing" ]]; then
    if [[ -z "${RANCHER_HOST:-}" ]]; then
      echo "ERROR: JOB_TYPE=existing requires RANCHER_HOST to be set."
      exit 1
    fi

    shopt -s nocasematch
    if [[ "${CREATE_INITIAL_CLUSTERS}" == "yes" ]]; then
      create_test_clusters
      wait_for_import_cluster
      # Read outputs (foreground, but keep consistent with recurring path)
      CUSTOM_NODE_IP=$(cat "${OUTPUTS_DIR}/customnode_ip.txt")
      CUSTOM_NODE_KEY=$(base64 -w 0 < "${SSH_KEY}")
      IMPORTED_KUBECONFIG=$(base64 -w 0 < "${OUTPUTS_DIR}/kubeconfig-import.yaml")
      echo "[init] Custom node: IP=${CUSTOM_NODE_IP}, Import cluster: kubeconfig ready"
    fi
    shopt -u nocasematch
  fi

  # NODEJS_VERSION adjustment for older Rancher
  if [[ -n "${RANCHER_VERSION}" ]] && [[ "${RANCHER_IMAGE_TAG}" != "head" ]]; then
    local major minor
    major=$(echo "${RANCHER_VERSION}" | cut -d. -f1)
    minor=$(echo "${RANCHER_VERSION}" | cut -d. -f2)
    if [[ "${major}" -le 2 ]] && [[ "${minor}" -lt 14 ]]; then
      NODEJS_VERSION="22.14.0"
      echo "[init] Adjusted NODEJS_VERSION=${NODEJS_VERSION} for Rancher ${RANCHER_VERSION} < 2.14"
    fi
  fi

  # CYPRESS_TAGS auto-adjustment
  if [[ -n "${CYPRESS_TAGS}" ]]; then
    if [[ "${CYPRESS_TAGS}" =~ "@bypass" ]]; then
      CYPRESS_TAGS=$(echo "${CYPRESS_TAGS}" | sed -e 's/@bypass//g' -e 's/[[:space:]][[:space:]]*/+/g' -e 's/++*/+/g' -e 's/^+//' -e 's/+$//' -e 's/+-$//')
    else
      if [[ "${RANCHER_HELM_REPO}" == "rancher-prime" || "${RANCHER_HELM_REPO}" == "rancher-latest" || "${RANCHER_HELM_REPO}" == "rancher-alpha" ]]; then
        [[ ! "${CYPRESS_TAGS}" =~ "@noPrime" ]] && CYPRESS_TAGS="${CYPRESS_TAGS}+-@noPrime"
      else
        [[ ! "${CYPRESS_TAGS}" =~ "@prime" ]] && CYPRESS_TAGS="${CYPRESS_TAGS}+-@prime"
      fi
      [[ ! "${CYPRESS_TAGS}" =~ "@noVai" ]] && CYPRESS_TAGS="${CYPRESS_TAGS}+-@noVai"
      CYPRESS_TAGS=$(echo "${CYPRESS_TAGS}" | sed -e 's/[[:space:]][[:space:]]*/+/g' -e 's/++*/+/g' -e 's/^+//' -e 's/+$//' -e 's/+-$//')
    fi
  fi

  # Write notification values for slack-notification.sh
  cat > "${JENKINS_WORKSPACE}/notification_values.txt" <<EOF
RANCHER_VERSION=${RANCHER_VERSION}
RANCHER_IMAGE_TAG=${RANCHER_IMAGE_TAG_RESOLVED:-${RANCHER_IMAGE_TAG}}
RANCHER_CHART_URL=${RANCHER_CHART_URL}
RANCHER_HELM_REPO=${RANCHER_HELM_REPO}
CYPRESS_TAGS=${CYPRESS_TAGS}
EOF

  # Export all vars for run.sh
  export NODEJS_VERSION DASHBOARD_REPO DASHBOARD_BRANCH CYPRESS_TAGS CYPRESS_VERSION
  export YARN_VERSION KUBECTL_VERSION RANCHER_USERNAME RANCHER_PASSWORD RANCHER_HOST
  export CHROME_VERSION RANCHER_TYPE="${JOB_TYPE}" CUSTOM_NODE_IP CUSTOM_NODE_KEY
  export RANCHER_IMAGE_TAG="${RANCHER_IMAGE_TAG_RESOLVED:-${RANCHER_IMAGE_TAG}}"
  export IMPORTED_KUBECONFIG="${IMPORTED_KUBECONFIG:-}"
  export RANCHER_VERSION

  echo ""
  echo "============================================================"
  echo " Infrastructure ready — Rancher: https://${RANCHER_HOST:-<existing>}"
  echo " Calling run.sh..."
  echo "============================================================"

  cd "${JENKINS_WORKSPACE}"
  bash "cypress/jenkins/run.sh"

  echo "Setup finished successfully."
}

if [[ "${1:-}" == "destroy" ]]; then
  # Need QA_INFRA_DIR for tofu_destroy to find the module
  QA_INFRA_DIR="${QA_INFRA_DIR:-${JENKINS_WORKSPACE}/qa-infra-automation}"
  TOFU_MODULE="${QA_INFRA_DIR}/tofu/aws/modules/cluster_nodes"
  destroy_all
else
  main
fi
