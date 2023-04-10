#!/bin/bash

# TODO poll pulp status API in plan, then run a script like this (or via structured hiera)
podman exec -it pulp mkdir -p /allowed_imports/RHEL-8-7-0-BaseOS-x86_64/{BaseOS,AppStream}/
podman exec -it pulp mkdir -p /allowed_imports/codeready-builder-for-rhel-8-x86_64-rpms/

podman cp  /run/media/$USER/RHEL-8-7-0-BaseOS-x86_64/BaseOS/ pulp:/allowed_imports/RHEL-8-7-0-BaseOS-x86_64/
podman cp  /run/media/$USER/RHEL-8-7-0-BaseOS-x86_64/AppStream/ pulp:/allowed_imports/RHEL-8-7-0-BaseOS-x86_64/
podman cp  codeready-builder-for-rhel-8-x86_64-rpms pulp:/allowed_imports/

podman exec -it pulp pip install pulp-rpm==3.19.4

podman container stop pulp
podman container start pulp
