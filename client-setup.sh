#!/bin/bash -e


# on host:
# https://serverfault.com/questions/987686/no-network-connectivity-to-from-docker-ce-container-on-centos-8
sudo firewall-cmd --zone=public --add-masquerade --permanent


loginctl enable-linger  # https://github.com/giuseppe/libpod/blob/allow-rootless-cni/troubleshooting.md#21-a-rootless-container-running-in-detached-mode-is-closed-at-logout
sed -i -e 's/^enabled=1/enabled=0/g' /etc/yum.repos.d/*.repo

for repo in simpbuild-6.6.0-baseos simpbuild-6.6.0-appstream simpbuild-6.6.0-epel simpbuild-6.6.0-epel-modular; do
  curl "http://localhost.localdomain:8080/pulp/content/$repo/config.repo" > "/etc/yum.repos.d/$repo.repo"
done

dnf module enable 389-directory-server:stable
dnf install 389-ds-base htop vim-ansible NetworkManager

dnf reposync --repo simpbuild-6.6.0-appstream,simpbuild-6.6.0-baseos,simpbuild-6.6.0-epel,simpbuild-6.6.0-epel-modular --download-path /run/testbuild-1-reposync --download-metadata -u
dnf reposync --repo simpbuild-6.6.0-appstream,simpbuild-6.6.0-baseos,simpbuild-6.6.0-epel,simpbuild-6.6.0-epel-modular --download-path /run/testbuild-1-reposync --download-metadata

for i in /etc/yum.repos.d/simpbuild-6.6.0-*.repo; do
  j="$( echo $i | sed -e 's/simpbuild-6.6.0/local/g')"
  k="$(basename "$i" .repo)"
  cp -v --force "$i" "$j"; sed -i \
    -e 's/^enabled=0/enabled=1/g' \
    -e 's/\[simpbuild/\[local/g' \
    -e "s@http://localhost.localdomain:80/pulp/content/@file:///run/testbuild-1-reposync/@g" \
    "$j"
done

