# @summary Manage a Pulp-in-one-container
# @param targets A single target to run on (the container host)
plan pulp3::in_one_container (
  TargetSpec           $targets          = "localhost",
  String[1]            $user             = system::env('USER'),
  Stdlib::AbsolutePath $container_root   = system::env('PWD'),
  String[1]            $container_name   = lookup('pulp3::in_one_container::container_name')|$k|{'pulp'},
  String[1]            $container_image  = lookup('pulp3::in_one_container::container_image')|$k|{'pulp/pulp'},
  Stdlib::Port         $container_port   = lookup('pulp3::in_one_container::container_port')|$k|{8080},
  Integer[0]           $startup_sleep_time = 10,
  Optional[Sensitive[String[1]]] $admin_password = Sensitive.new(system::env('PULP3_ADMIN_PASSWORD').lest||{'admin'}),
  Optional[Enum[podman,docker]] $runtime = undef,
  # FIXME not set up yet:
  Array[Stdlib::AbsolutePath] $import_paths = lookup('pulp3::in_one_container::import_paths')|$k|{
    [ "${container_root}/run/ISOs/unpacked" ]
  },
) {
  $host = run_plan('pulp3::in_one_container::get_host', 'targets' => $targets, 'runtime' => $runtime)
  $runtime_exe            = $host.facts['pioc_runtime_exe']
  $apply_el7_docker_fixes = $host.facts['pioc_apply_el7_docker_fixes']

  if $runtime_exe == 'docker' and $apply_el7_docker_fixes {
    # docker socket hack
    # FIXME move this into another, more env-specific plan
    $setfacl_result = run_command(
      "setfacl --modify 'user:${user}:rw' /var/run/docker.sock",
      $host,
      {'_run_as' => 'root' },
    )
  }

  if run_plan( 'pulp3::in_one_container::match_container', {
    'host'  => $host,
    'name'  => $container_name,
    'image' => $container_image,
  }){
    out::message( "Container '${container_name}' already running!" )
    return undef
  }

  if run_plan( 'pulp3::in_one_container::match_container', {
    'host'  => $host,
    'name'  => $container_name,
    'image' => $container_image,
    'all'   => true,
  }){
    out::message( "Restarting stopped container '${container_name}'..." )
    return run_command( "${runtime_exe} container start ${container_name}", $host )
  }

  out::message( "Starting new container '${container_name}' from image '${container_image}'..." )
  $apply_result = run_plan(
    'pulp3::in_one_container::apply_local_filesystem',
    {
      'host'           => $host,
      'container_root' => $container_root,
      'container_port' => $container_port,
      'import_paths'   => $import_paths,
    }
  )

  $selinux_suffix = $host.facts['selinux_enforced'] ? {
    true    => ':Z',
    default => '',
  }
  $start_cmd = @("START_CMD"/n)
    ${runtime_exe} run --detach \
      --name "${container_name}" \
      --publish "${container_port}:80" \
      --log-driver journald \
      --device /dev/fuse \
      --volume "${container_root}/settings:/etc/pulp${selinux_suffix}" \
      --volume "${container_root}/pulp_storage:/var/lib/pulp${selinux_suffix}" \
      --volume "${container_root}/pgsql:/var/lib/pgsql${selinux_suffix}" \
      --volume "${container_root}/containers:/var/lib/containers${selinux_suffix}" \
      --volume "${container_root}/run:/run${selinux_suffix}" \
      "${container_image}"
    | START_CMD

  $start_result = run_command($start_cmd, $host)

  ctrl::sleep($startup_sleep_time)
  out::message("Waiting ${startup_sleep_time} seconds for pulp to start up...")
  $admin_pw_result = run_plan(
    'pulp3::in_one_container::reset_admin_password',
    'targets'        => $host,
    'container_name' => $container_name,
  )

}
