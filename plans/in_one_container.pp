# @summary Ensure a Pulp-in-one-container container is configured and running
# @param targets A single target to run on (the container host)
# @param container_name Name of target Docker/podman container
# @param container_image Target Docker/podman image
# @param container_port Pulp3 HTTP port on target Docker/podman container
# @param runtime Container runtime executable to use (`undef` = autodetect)
# @param startup_sleep_time Time (secs) to wait before configuring Pulp3 admin
plan pulp3::in_one_container (
  TargetSpec                     $targets            = 'localhost',
  String[1]                      $user               = system::env('USER'),
  Stdlib::AbsolutePath           $container_root     = system::env('PWD'),
  String[1]                      $container_name     = lookup('pulp3::in_one_container::container_name')|$k|{'pulp'},
  String[1]                      $container_image    = lookup('pulp3::in_one_container::container_image')|$k|{'pulp/pulp'},
  Stdlib::Port                   $container_port     = lookup('pulp3::in_one_container::container_port')|$k|{8080},
  Integer[0]                     $startup_sleep_time = lookup('pulp3::in_one_container::startup_sleep_time')|$k|{60},
  Boolean                        $skip_filesystem    = false,
  Optional[Sensitive[String[1]]] $admin_password     = Sensitive.new(system::env('PULP3_ADMIN_PASSWORD').lest||{'admin'}),
  Optional[Enum[podman,docker]]  $runtime            = undef,
  String[1]                      $log_level          = lookup('pulp3::in_one_container::log_level')|$k|{'INFO'},
  # FIXME not set up yet:
  Array[Stdlib::AbsolutePath] $import_paths          = lookup('pulp3::in_one_container::import_paths')|$k|{
    [ "${container_root}/run/ISOs/unpacked" ]
  },
) {
  $host = run_plan('pulp3::in_one_container::get_host', 'targets' => $targets, 'runtime' => $runtime)
  $runtime_exe = $host.facts['pioc_runtime_exe']

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
    'port'  => $container_port,
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
  })

  $settings_result = run_plan(
    'pulp3::in_one_container::create_settings', {
      'host'           => $host,
      'runtime_exe'    => $runtime_exe,
      'container_name' => $container_name,
      'container_port' => $container_port,
      'host_baseurl'   => 'http://127.0.0.1',
      'log_level'      => $log_level,
  })
  $start_cmd = @("START_CMD"/n)
    ${runtime_exe} run --detach \
      --name "${container_name}" \
      --publish "${container_port}:80" \
      --publish-all \
      --log-driver journald \
      --device /dev/fuse \
      --volume "${container_name}-settings:/etc/pulp" \
      --volume "${container_name}-storage:/var/lib/pulp" \
      --volume "${container_name}-pgsql:/var/lib/pgsql" \
      --volume "${container_name}-containers:/var/lib/containers" \
      --volume "${container_name}-run:/run" \
      "${container_image}"
    | START_CMD

  $start_result = run_command($start_cmd, $host)

  out::message("Waiting ${startup_sleep_time} seconds for pulp to start up...")
  ctrl::sleep($startup_sleep_time)
  $admin_pw_result = run_plan(
    'pulp3::in_one_container::reset_admin_password',
    'targets'        => $host,
    'container_name' => $container_name,
  )

  # TODO: optional automated post-install tasks
  # - Creating/Uploading /allowed_imports/* content (RHEL ISOs, rpms)
  # - Updating the pulp container
  #
  # Automating the build should be another plan at the same level as this logic (which should probably be refactored into a sub-plan
}
