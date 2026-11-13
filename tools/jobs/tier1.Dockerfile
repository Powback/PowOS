# tools/jobs/tier1.Dockerfile - the tier1 job (compose.yml): test/tier1/run-all.sh over the baked source.
# bash 5, python3, jq, shellcheck, mksh (Android's sh, for the device-script simulations), git, tmux, zip (ship-order-test), rsync, g++, node 22, the docker CLI. The source
# goes in last, so only that layer rebuilds per run. The source becomes a one-commit git repo: tests that ask git for
# the toplevel or ls-files see the working state. The engine: compose.yml gives this job its machine's own engine
# socket as DOCKER_HOST, and `docker` is tools/jobs/docker-sibling.sh (bind mounts of the job's paths copied into the
# sibling containers), so the tests that need one (complexity's detekt/clippy, loopback-unix, publish-repo) run here.
FROM docker.io/library/ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash python3 python3-pip jq shellcheck mksh git tmux ca-certificates curl gnupg zip unzip rsync g++ \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && git config --system user.email jobs@powos.local && git config --system user.name powos-jobs \
    && git config --system init.defaultBranch main && git config --system --add safe.directory '*'
# The docker CLI only (no engine): Docker's apt repo, this image's arch.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
SHELL ["/bin/bash", "-c"]
COPY . /src
WORKDIR /src
RUN rm -rf .jobs && git init -q && git add -A && git commit -qm "job source" --no-verify \
    && ln -sf /src/tools/jobs/docker-sibling.sh /usr/local/bin/docker
ENTRYPOINT ["bash", "test/tier1/run-all.sh"]
