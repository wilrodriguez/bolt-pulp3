#!/bin/bash -e

# For docker clients to connect to docker PIOC-hosted forwarded ports
# on host:
# https://serverfault.com/questions/987686/no-network-connectivity-to-from-docker-ce-container-on-centos-8
sudo firewall-cmd --zone=public --add-masquerade --permanent

# docker socket hack
sudo setfacl --modify 'user:${USER}:rw' /var/run/docker.sock",

#docker pull centos:8
#docker container run -i -d -t centos:8 el8-client-1
#docker container run -i -d -t centos:8 el8-client-2
