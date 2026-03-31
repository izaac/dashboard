# Jenkins CI Pipeline

Thin Jenkins wrapper for the Dashboard E2E test pipeline. The actual test
infrastructure (Dockerfile, Cypress config, playbook) lives in the
[qa-infra-automation](https://github.com/rancher/qa-infra-automation/tree/main/ansible/testing/dashboard-e2e)
repo. This directory only contains what Jenkins needs to kick things off.

## Files

| File | What it does |
|------|-------------|
| `Jenkinsfile` | Pipeline stages — checkout, run tests, grab results, cleanup, Slack |
| `Jenkinsfile_multi` | Matrix job — fans out across Rancher versions × K8s versions × tag sets |
| `init.sh` | Installs prerequisites, clones qa-infra-automation, generates vars.yaml, runs playbook, runs Docker |
| `slack-notification.sh` | Posts test results to Slack on failure |

## How it works

```
Jenkinsfile → init.sh → ansible-playbook (provision + setup) → docker run (streaming)
                      ↘ init.sh destroy → ansible-playbook --tags cleanup
```

1. **Jenkinsfile** checks out this repo, runs `init.sh`, collects results, and
   handles cleanup in a `finally` block.

2. **init.sh** installs tools (tofu, ansible, kubectl, helm) with SHA256
   verification, clones qa-infra-automation, writes `vars.yaml` from the
   `VARS_YAML_CONFIG` Jenkins text area, then:
   - Runs the playbook with `--skip-tags test` (provision + setup)
   - Runs `docker run` directly for real-time streaming with colors
   - On destroy: runs the playbook with `--tags cleanup,never`

3. **The playbook** handles everything else — provisioning AWS infra, deploying
   Rancher, cloning dashboard, building the Docker image. See the
   [playbook README](https://github.com/rancher/qa-infra-automation/tree/main/ansible/testing/dashboard-e2e)
   for configuration, stage tags, and standalone usage.

## Configuration

All configuration is done via the `VARS_YAML_CONFIG` text area in Jenkins.
This is a YAML block that becomes the playbook's `vars.yaml`. See
[vars.yaml.example](https://github.com/rancher/qa-infra-automation/blob/main/ansible/testing/dashboard-e2e/vars.yaml.example)
for all available options.

Jenkins-level parameters (not in vars.yaml):

| Parameter | Default | Description |
|-----------|---------|-------------|
| `BRANCH` | `master` | Branch for Jenkinsfile and init.sh (not test code) |
| `QA_INFRA_BRANCH` | `dashboard_tests` | Branch of qa-infra-automation to clone |
| `CLEANUP` | `true` | Destroy infrastructure after the run (`false`/`no`/`0` to skip) |
| `SLACK_NOTIFICATION` | `true` | Post to Slack on failure |
| `ANSIBLE_VERBOSITY` | `0` | Ansible output verbosity (0–4) |

## Tools installed automatically

`init.sh` downloads pinned versions with SHA256 checksums. No pre-install
needed beyond Docker and git on the Jenkins executor.

| Tool | Version | Purpose |
|------|---------|---------|
| OpenTofu | 1.11.5 | AWS infrastructure provisioning |
| uv | 0.11.2 | Ansible installer |
| Ansible | core < 2.17 | Playbook execution (pinned for Python 3.8 target compat) |
| kubectl | v1.29.8 | Cluster verification |
| Helm | 3.17.3 | Chart version resolution |
