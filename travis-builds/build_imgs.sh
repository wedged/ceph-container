#!/usr/bin/env bash
set -xe

# FUNCTIONS
# NOTE (leseb): how to choose between directory for multiple change?
# using "head" as a temporary solution

function get_dirs {
  # Are we testing a pull request?
  if [[ ( -d daemon || -d base) && -d demo ]]; then
    # We are running on a pushed "release" branch, not a PR. Do nothing here.
    return 0
  fi
  # We are testing a PR. Copy the directories.
  dir_to_test="$(git diff origin/master..HEAD --name-only ceph-releases/* | cut -d/ -f 1-4 | sort -u)"
  if [[ $(echo "$dir_to_test" | grep -q "kraken/ubuntu/16.04") == 0 ]]; then
    dir_to_test='ceph-releases/kraken/ubuntu/16.04'
  else
    for dir in $dir_to_test; do DIR_TO_TEST+=("$dir"); done
  fi
}

function copy_dirs {
  if [[ ! -z "${1}" ]]; then
    mkdir -p {base,daemon,demo}
    cp -Lrv "${1}"/base/* base || true
    cp -Lrv "${1}"/daemon/* daemon
    cp -Lrv "${1}"/demo/* demo || true # on Luminous demo has merged with daemon
  else
    echo "looks like your commit did not bring any changes"
    echo "building Luminous on Ubuntu 16.04"
    mkdir -p {daemon,demo}
    cp -Lrv ceph-releases/luminous/ubuntu/16.04/daemon/* daemon
  fi
}

function build_base_img {
if [[ -d base ]] && [[ "$(find base -type f | wc -l)" -gt 1 ]]; then
    pushd base
    docker build -t base .
    popd
    rm -rf base
  fi
}

function build_daemon_img {
  pushd daemon
  if grep "FROM ceph/base" Dockerfile; then
    sed -i 's|FROM .*|FROM base|g' Dockerfile
  fi
  docker build -t ceph/daemon .
  popd
  rm -rf daemon
}

function build_demo_img {
  if [[ -d demo ]] && [[ "$(find demo -type f | wc -l)" -gt 1 ]]; then
    pushd demo
    if grep "FROM ceph/base" Dockerfile; then
      sed -i 's|FROM .*|FROM base|g' Dockerfile
    fi
  popd
  rm -rf demo
  fi
}

# MAIN
get_dirs
for dir in "${DIR_TO_TEST[@]}"
do
  copy_dirs "${dir}"
  build_base_img
  build_daemon_img
  build_demo_img
done
