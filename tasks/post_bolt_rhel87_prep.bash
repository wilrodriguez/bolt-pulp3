#!/usr/bin/env bash

set -x
set -euo pipefail

for v in ${!PT_*}; do
  echo "=============== ${v}"
  declare "${v#*PT_}"="${!v}"
done


env > /home/chris/src/simp-core-pretty/bolt-pulp3/BOLT.ENV.VARS.txt

PULP_CONTAINER_NAME="${PT_pulp_container_name:-pulp}"
MOUNTED_ISO_ROOT_DIR="${PT_rhel_iso_root_dir:-"/run/media/$USER/RHEL-8-7-0-BaseOS-x86_64"}"
RUNTIME_EXE=podman

echo "PULP_CONTAINER_NAME: '${PULP_CONTAINER_NAME}'"
echo "MOUNTED_ISO_ROOT_DIR: '${MOUNTED_ISO_ROOT_DIR}'"

[[ -d "$MOUNTED_ISO_ROOT_DIR" ]] || { >&2 echo "ERROR: No ISO directory found at ${MOUNTED_ISO_ROOT_DIR}"; exit 99; }

# TODO poll pulp status API in plan, then run a script like this (or via structured hiera)
"$RUNTIME_EXE" exec -it "$PULP_CONTAINER_NAME" mkdir -p /allowed_imports/RHEL-8-7-0-BaseOS-x86_64/{BaseOS,AppStream}/
"$RUNTIME_EXE" exec -it "$PULP_CONTAINER_NAME" mkdir -p /allowed_imports/codeready-builder-for-rhel-8-x86_64-rpms/

"$RUNTIME_EXE" cp  "$MOUNTED_ISO_ROOT_DIR/BaseOS/" "$PULP_CONTAINER_NAME":/allowed_imports/RHEL-8-7-0-BaseOS-x86_64/
"$RUNTIME_EXE" cp  "$MOUNTED_ISO_ROOT_DIR/AppStream/" "$PULP_CONTAINER_NAME":/allowed_imports/RHEL-8-7-0-BaseOS-x86_64/
"$RUNTIME_EXE" cp  codeready-builder-for-rhel-8-x86_64-rpms "$PULP_CONTAINER_NAME":/allowed_imports/

"$RUNTIME_EXE" exec -it "$PULP_CONTAINER_NAME" pip install --upgrade-strategy only-if-needed 'pulp-rpm>=3.19.4'

"$RUNTIME_EXE" container stop "$PULP_CONTAINER_NAME"
"$RUNTIME_EXE" container start "$PULP_CONTAINER_NAME"
