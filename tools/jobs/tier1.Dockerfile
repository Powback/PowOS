# tools/jobs/tier1.Dockerfile - the tier1 job (compose.yml): test/tier1/run-all.sh over the baked source.
# bash 5, python3, jq, shellcheck, git, tmux, zip (ship-order-test), rsync (test-offload), g++, node 22. The source goes in last, so only that layer
# rebuilds per run. The source becomes a one-commit git repo: tests that ask git for the toplevel or ls-files see the
# working state. No docker socket inside: the 3 tests that need one (complexity's detekt/clippy, loopback-unix,
# publish-repo) SKIP, the same on every machine.
FROM docker.io/library/ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash python3 python3-pip jq shellcheck git tmux ca-certificates curl gnupg zip unzip rsync g++ \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && git config --system user.email jobs@powos.local && git config --system user.name powos-jobs \
    && git config --system init.defaultBranch main && git config --system --add safe.directory '*'
SHELL ["/bin/bash", "-c"]
COPY . /src
WORKDIR /src
RUN rm -rf .jobs && git init -q && git add -A && git commit -qm "job source" --no-verify
ENTRYPOINT ["bash", "test/tier1/run-all.sh"]
