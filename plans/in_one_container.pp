# @summary Manage a Pulp-in-one-container
# @param targets A single target to run on (the container host)
plan pulp3::in_one_container (
  TargetSpec                     $targets            = 'localhost',
  String[1]                      $user               = system::env('USER'),
  Stdlib::AbsolutePath           $container_root     = system::env('PWD'),
  String[1]                      $container_name     = lookup('pulp3::in_one_container::container_name')|$k|{'pulp'},
  String[1]                      $container_image    = lookup('pulp3::in_one_container::container_image')|$k|{'pulp/pulp'},
  Stdlib::Port                   $container_port     = lookup('pulp3::in_one_container::container_port')|$k|{8080},
  Integer[0]                     $startup_sleep_time = 10,
  Boolean                        $skip_filesystem    = false,
  Optional[Sensitive[String[1]]] $admin_password     = Sensitive.new(system::env('PULP3_ADMIN_PASSWORD').lest||{'admin'}),
  Optional[Enum[podman,docker]]  $runtime            = undef,
  # FIXME not set up yet:
  Array[Stdlib::AbsolutePath] $import_paths          = lookup('pulp3::in_one_container::import_paths')|$k|{
    [ "${container_root}/run/ISOs/unpacked" ]
  },
) {
  $host = run_plan('pulp3::in_one_container::get_host', 'targets'              => $targets, 'runtime' => $runtime)
  $runtime_exe            = $host.facts['pioc_runtime_exe']
  $apply_el7_docker_fixes = $host.facts['pioc_apply_el7_docker_fixes']

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
    'pulp3::in_one_container::volumes::create', {
      'host'           => $host,
      'runtime_exe'    => $runtime_exe,
      'container_name' => $container_name,
      'container_port' => $container_port
    }
  )

  $start_cmd = @("START_CMD"/n)
    ${runtime_exe} run --detach \
      --name "${container_name}" \
      --publish "${container_port}:80" \
      --publish-all \
      --log-driver journald \
      --device /dev/fuse \
      --volume "pulp-settings:/etc/pulp" \
      --volume "pulp-storage:/var/lib/pulp" \
      --volume "pulp-pgsql:/var/lib/pgsql" \
      --volume "pulp-containers:/var/lib/containers" \
      --volume "pulp-run:/run" \
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
