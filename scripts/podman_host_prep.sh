#!/bin/bash -e

# FIXME # can't get podman rootless containers to connect to each other like rootful docker can


loginctl enable-linger  # https://github.com/giuseppe/libpod/blob/allow-rootless-cni/troubleshooting.md#21-a-rootless-container-running-in-detached-mode-is-closed-at-logout
