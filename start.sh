#!/bin/bash -eu

set -o pipefail

CONTAINER_name="${CONTAINER_name:-pulp}"
CONTAINER_full_name="${CONTAINER_full_name:-pulp/pulp}"
CONTAINER_port="${CONTAINER_port:-8080}"
CONTAINER_runtime="${CONTAINER_runtime:-docker}"
CONTAINER_action=start

destroy_container()
{
  docker kill "$CONTAINER_name" || :
  docker rm "$CONTAINER_name" || :
}

remove_directories()
{
  sudo rm -rf \
    settings \
    pulp_storage \
    pgsql \
    containers \
    run
}

ensure_setup()
{
  # Ensure volume mounts
###  mkdir -p settings pulp_storage pgsql containers run
  mkdir -p settings pulp_storage pgsql containers run/postgresql
  chmod a+w run/postgresql

  # Ensure settings
  if [ ! -f settings/settings.py ]; then
    cat >> settings/settings.py <<SETTINGS
CONTENT_ORIGIN='http://$(hostname):$CONTAINER_port'
ANSIBLE_API_HOSTNAME='http://$(hostname):$CONTAINER_port'
ANSIBLE_CONTENT_HOSTNAME='http://$(hostname):$CONTAINER_port/pulp/content'
TOKEN_AUTH_DISABLED=True
SETTINGS
  fi
}



run_docker()
{
  # In case I forget to set up the socket config again
  sudo setfacl --modify "user:$USER:rw" /var/run/docker.sock

  if docker container ls --format="{{.Image}}  {{.ID}}  {{.Names}}" \
    | grep -w  "$CONTAINER_full_name  .*\<$CONTAINER_name\>"; then
    echo "Container '$CONTAINER_name' already running!"
    return
  fi

  if docker container ls -a --format="{{.Image}}  {{.ID}}  {{.Names}}" \
    | grep -w  "$CONTAINER_full_name  .*\<$CONTAINER_name\>"; then
    echo "Starting stopped container '$CONTAINER_name'..."
    docker container start $CONTAINER_name
    return
  fi


  echo "Starting new container '$CONTAINER_full_name'..."
  ensure_setup

  # Start container
  docker run --detach \
    --publish "$CONTAINER_port:80" \
    --name "$CONTAINER_name" \
    --volume "$PWD/settings:/etc/pulp:Z" \
    --volume "$PWD/pulp_storage:/var/lib/pulp:Z" \
    --volume "$PWD/pgsql:/var/lib/pgsql:Z" \
    --volume "$PWD/containers:/var/lib/containers:Z" \
    --volume "$PWD/run:/run:Z" \
    --device /dev/fuse \
    "$CONTAINER_full_name"
}


run_podman()
{
  echo "Starting new container '$CONTAINER_full_name'..."
  ensure_setup

  # Start container
  podman run --detach \
    --publish "$CONTAINER_port:80" \
    --name "$CONTAINER_name" \
    --volume "$PWD/settings:/etc/pulp:Z" \
    --volume "$PWD/pulp_storage:/var/lib/pulp:Z" \
    --volume "$PWD/pgsql:/var/lib/pgsql:Z" \
    --volume "$PWD/containers:/var/lib/containers:Z" \
    --volume "$PWD/run:/run:Z" \
    --device /dev/fuse \
    "$CONTAINER_full_name"
}


echo_help()
{
  echo
  printf "Usage: %s [options]\n\n" %s
  echo Options:
  printf "\t%02s %08s\t%s\n" -h '' 'This help message'
  printf "\t%02s %08s\t%s\n" -r RUNTIME "Container runtime ('docker' or 'podman') Default: $CONTAINER_runtime"
  printf "\t%02s %08s\t%s\n" -p PORT    "Container port (Default: $CONTAINER_port)"
  printf "\t%02s %08s\t%s\n" -n NAME    "Container name (Default: $CONTAINER_name)"
  printf "\t%02s %08s\t%s\n" -a ACTION  "Action: [start|destroy|reset-admin-password] (Default: $CONTAINER_action)"
  echo
}
while getopts ":hn:p:r:a:" opt; do
  case ${opt} in
    h ) echo_help; exit 0
      ;;
    n )
      CONTAINER_name="$OPTARG"
      ;;
    p )
      CONTAINER_port="$OPTARG"
      ;;
    r )
      CONTAINER_runtime="$OPTARG"
      ;;
    a )
      CONTAINER_action="$OPTARG"
      ;;
    : )
      >&2 echo "Invalid option: -$OPTARG requires an argument"; echo_help; exit 1
      ;;
    \? )
      >&2 echo "Invalid option: -$OPTARG"; echo_help; exit 1
      ;;
  esac
done

case "$CONTAINER_action" in
  start)
    if [[ "$CONTAINER_runtime" == "docker" ]]; then
      run_docker
    else
      run_podman
    fi
    ;;
  reset-admin-password)
    printf "Run this command:\n\n\t"
    printf "$CONTAINER_runtime exec -it $CONTAINER_name bash -c 'pulpcore-manager reset-admin-password'"
    printf "\n\n"
    ;;
  destroy)
    destroy_container
    remove_directories
    ;;
  kill)
    destroy_container
    ;;
  *)
    >&2 echo "Invalid option: -$OPTARG"; echo_help; exit 1
    ;;
esac


