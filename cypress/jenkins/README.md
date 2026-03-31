# Jenkins CI Pipeline

This directory contains the Jenkins pipeline that runs Rancher Dashboard E2E tests.
It automatically spins up AWS infrastructure, installs Rancher, and runs Cypress
tests against it. When the tests finish (pass or fail), everything is torn down.

## How it works

The pipeline flows through three scripts:

```
Jenkinsfile  →  init.sh  →  run.sh  →  cypress.sh (inside Docker)
```

1. **`Jenkinsfile`** kicks things off in Jenkins — checks out the repo, runs init.sh,
   collects results, and handles cleanup.

2. **`init.sh`** does the heavy lifting — installs any missing tools (tofu, ansible,
   kubectl, helm), spins up EC2 instances with OpenTofu, installs k3s clusters with
   Ansible, and deploys Rancher via Helm. When infrastructure is ready, it calls run.sh.

3. **`run.sh`** takes over from there — creates a `standard_user` in Rancher (for
   standard-user tests), clones the correct dashboard branch, builds a Docker image
   with Cypress and Chrome, and runs the tests.

4. **`cypress.sh`** is the entrypoint inside the Docker container — it filters test
   specs by tags and runs Cypress.

## What gets provisioned

When `JOB_TYPE=recurring` (the default), three things are created **in parallel**:

- **Rancher Server** — a 3-node k3s HA cluster with Rancher installed via Helm.
  Gets a real DNS name under your Route53 zone.
- **Import Cluster** — a single-node k3s cluster used by tests that import
  an existing cluster into Rancher.
- **Custom Node** — a bare EC2 instance (no k3s) used by tests that create
  custom clusters through the Rancher UI.

When `JOB_TYPE=existing`, it skips Rancher provisioning entirely and points
tests at an already-running Rancher instance (set via `RANCHER_HOST`).

## All the files

| File | What it does |
|------|-------------|
| `Jenkinsfile` | Pipeline stages — checkout, run tests, grab results, cleanup |
| `init.sh` | Tool installation, infrastructure provisioning, calls run.sh |
| `run.sh` | Rancher user setup, dashboard clone, Docker build, test execution |
| `configure.sh` | Generates the `~/.env` file passed into the Docker container |
| `Dockerfile.ci` | Docker image — Cypress + Chrome + kubectl + kubeconfig |
| `cypress.sh` | Runs Cypress inside the container with tag-based spec filtering |
| `cypress.config.jenkins.ts` | Cypress config tuned for CI (retries, reporters, etc.) |
| `grep-filter.ts` | TypeScript script that pre-filters spec files matching grep tags |
| `utils.sh` | Shared shell helpers (tag normalization, etc.) |
| `slack-notification.sh` | Posts test results to Slack when builds fail |

## Job types at a glance

| `JOB_TYPE` | `CREATE_INITIAL_CLUSTERS` | What happens |
|------------|--------------------------|--------------|
| `recurring` | `yes` | Full provisioning — Rancher + test clusters |
| `recurring` | `no` | Rancher only, no import/custom clusters |
| `existing` | `yes` | Uses your Rancher, creates test clusters |
| `existing` | `no` | Uses your Rancher, no clusters — just runs tests |

Values for `CREATE_INITIAL_CLUSTERS` accept `true`/`yes`/`1` (and `false`/`no`/`0`).

## Tools installed automatically

You don't need to pre-install anything on the Jenkins executor beyond Docker and git.
`init.sh` downloads everything else with SHA256 checksum verification:

| Tool | Pinned version | Used for |
|------|---------------|----------|
| OpenTofu | 1.11.5 | Creating EC2 instances, DNS records |
| uv | 0.11.2 | Installing Ansible in an isolated environment |
| Ansible | core < 2.17 | Running k3s and Rancher playbooks |
| kubectl | v1.29.8 | Verifying cluster readiness |
| Helm | 3.17.3 | Resolving Rancher chart versions |

## Environment variables you need to set

These are **required** — typically configured as Jenkins credentials:

| Variable | What it is |
|----------|-----------|
| `AWS_ACCESS_KEY_ID` | AWS access key |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key |
| `AWS_AMI` | EC2 AMI ID (should be Ubuntu 20.04) |
| `AWS_ROUTE53_ZONE` | Your Route53 DNS zone |
| `AWS_VPC` | VPC ID where instances are launched |
| `AWS_SUBNET` | Subnet ID within the VPC |
| `AWS_SECURITY_GROUP` | Security group ID (needs ports 22, 80, 443, 6443 open) |

## Environment variables you can optionally set

These all have sensible defaults — override them via Jenkins job parameters
when you need something different:

| Variable | Default | What it controls |
|----------|---------|-----------------|
| `RANCHER_IMAGE_TAG` | `v2.14-head` | Which Rancher version to deploy |
| `RANCHER_HELM_REPO` | `rancher-com-rc` | Helm chart source (prime, latest, alpha, etc.) |
| `RANCHER_PASSWORD` | `password1234` | Password for admin and standard_user |
| `BOOTSTRAP_PASSWORD` | `password` | Rancher's initial bootstrap password |
| `K3S_KUBERNETES_VERSION` | `v1.30.0+k3s1` | K3s version for all clusters |
| `SERVER_COUNT` | `3` | Number of nodes in the Rancher cluster |
| `CYPRESS_TAGS` | `@adminUser` | Which test tags to run |
| `JOB_TYPE` | `recurring` | `recurring` (provision everything) or `existing` |
| `CREATE_INITIAL_CLUSTERS` | `true` | Whether to create import/custom clusters (accepts `true`/`yes`/`1`) |
| `RANCHER_HOST` | *(auto-generated)* | Required when `JOB_TYPE=existing` |
| `QA_INFRA_REPO` | `rancher/qa-infra-automation` | Infrastructure playbooks repo |
| `QA_INFRA_BRANCH` | `main` | Branch of the infra repo |
| `ANSIBLE_VERBOSITY` | `0` | Ansible output verbosity (0 = quiet, 4 = max) |
| `CLEANUP` | `true` | Destroy infrastructure after the run |
| `SLACK_NOTIFICATION` | `true` | Post results to Slack on failure |
| `QASE_PROJECT` | `RM` | Qase project code for test reporting |
| `QASE_REPORT` | `true` | Enable Qase test reporting |

## Where things end up

During a run, generated files live in `~/.qa-infra/outputs/`:

- `*.tfvars` — Terraform variable files for each cluster
- `*-inventory.yml` — Ansible inventories
- `kubeconfig-*.yaml` — Kubeconfigs for Rancher and import clusters
- `id_rsa` / `id_rsa.pub` — Ephemeral SSH key (generated per run)

Test results are written to:

- `~/dashboard/results.xml` — JUnit XML (consumed by Jenkins)
- `~/dashboard/cypress/reports/html/` — HTML report (published in Jenkins)

Both are cleaned up by the Pre-Clean and Cleanup stages in the Jenkinsfile.
