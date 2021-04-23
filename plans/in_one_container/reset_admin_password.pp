# @summary Manage a Pulp-in-one-container
# @param targets A single target to run on (the container host)
plan pulp::in_one_container::reset_admin_password (
  TargetSpec           $targets         = "localhost",
  String[1]            $user            = system::env('USER'),
  Stdlib::AbsolutePath $container_root  = system::env('PWD'),
  String[1]            $container_name  = lookup('pulp::in_one_container::container_name')|$k|{'pulp'},
  String[1]            $container_image = lookup('pulp::in_one_container::container_image')|$k|{'pulp/pulp'},
  Stdlib::Port         $container_port  = lookup('pulp::in_one_container::container_port')|$k|{8080},
  Optional[Sensitive[String[1]]] $admin_password  = Sensitive.new(system::env('PULP3_ADMIN_PASSWORD').lest||{'admin'}),
  Optional[Enum[podman,docker]] $runtime = undef,
  # FIXME not set up yet:
  Array[Stdlib::AbsolutePath] $import_paths = lookup('pulp::in_one_container::import_paths')|$k|{
    [ "${container_root}/run/ISOs/unpacked" ]
  },
  Boolean $noop = false,
  #  Enum[start,stop,destroy,directories,reset-admin-password] $action = 'start',
) {
  $host = get_target($targets)
  run_plan('facts', 'targets' => $host)

  $apply_el7_docker_fixes = (
    $host.facts['os']['family'] == 'Redhat' and
    $host.facts['os']['release']['major'] == '7'
  )

  $runtime_exe = run_plan(
    'pulp::in_one_container::validate_container_exe',
    {
      'host'                   => $host,
      'apply_el7_docker_fixes' => $apply_el7_docker_fixes,
      'runtime'                => $runtime,
    }
  )

  ###$admin_reset_cmd = "${runtime_exe} exec -it ${container_name} bash -c 'pulpcore-manager reset-admin-password -p \"\$PULP3_ADMIN_PASSWORD\"'"
  $admin_reset_cmd = "${runtime_exe} exec -it ${container_name} bash -c '/bin/sh -c pulpcore-manager reset-admin-password -p \"admin\"'"
  out::message( "Running:\n\n\t${admin_reset_cmd}\n" )
  $reset_result = run_command($admin_reset_cmd, $host, {
    '_env_vars' => { 'PULP3_ADMIN_PASSWORD' => $admin_password.unwrap },
  })
  debug::break()
  return $reset_result
}
