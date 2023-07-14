FROM registry.suse.com/bci/golang:1.19

# Configure Go
ENV GOPATH /opt
ENV PATH ${PATH}:/opt/bin
ENV GITHUB_URL "https://github.com/"
ARG CORRAL_VERSION=v1.1.1
ARG RANCHER_REPO_BRANCH=release/v2.7
ARG RANCHER_REPO_PATH=rancher/rancher.git
ARG DASHBOARD_REPO=rancher/dashboard.git
ARG DASHBOARD_BRANCH=master
ENV DASHBOARD_REPO=${DASHBOARD_REPO}
ENV DASHBOARD_BRANCH=${DASHBOARD_BRANCH}
ARG CORRAL_PACKAGES_BRANCH=main
ARG CORRAL_PACKAGES_REPO=rancherlabs/corral-packages
ENV CORRAL_PACKAGES_BRANCH=${CORRAL_PACKAGES_BRANCH}
ENV CORRAL_PACKAGES_REPO=${CORRAL_PACKAGES_REPO}

RUN zypper -n install gcc binutils glibc-devel-static \ 
  ca-certificates git-core wget curl unzip tar \
  less file xz gzip sed
# RUN zypper install -y -f docker && \
#   rpm -e --nodeps --noscripts containerd

# The following variables come with --with-env

# RUN git clone -b ${RANCHER_REPO_BRANCH} \
#     ${GITHUB_URL}${RANCHER_REPO_PATH} \
#     ${GOPATH}/src/github.com/rancher/rancher

RUN git clone -b ${CORRAL_PACKAGES_BRANCH} \
  ${GITHUB_URL}${CORRAL_PACKAGES_REPO} \
  ${GOPATH}/src/github.com/rancherlabs/corral-packages

# TEMPORARY PATH FOR LOCAL DEV
ENV DASHBOARD /opt/dashboard
RUN git clone -b ${DASHBOARD_BRANCH} \
  ${GITHUB_URL}${DASHBOARD_REPO} ${DASHBOARD} 

ENV WORKSPACE ${GOPATH}/src/github.com/rancher/rancher
WORKDIR ${WORKSPACE}

# The following two lines COPY emulate Jenkins config create
COPY ["*.sh", "${DASHBOARD}/jenkins"]
COPY ["rancher", "${WORKSPACE}"]
COPY ["./izaac_test_go_min.yaml", "${WORKSPACE}/tests/v2/validation/config.yml"]
ENV CATTLE_TEST_CONFIG=${WORKSPACE}/tests/v2/validation/config.yml

ARG CORRAL_VERSION=v1.1.1
RUN go mod download && \
    go install gotest.tools/gotestsum@latest && \
    go install github.com/rancherlabs/corral@${CORRAL_VERSION}