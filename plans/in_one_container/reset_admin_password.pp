# @summary Manage a Pulp-in-one-container
# @param targets A single target to run on (the container host)
plan pulp3::in_one_container::reset_admin_password (
  TargetSpec                     $targets        = 'localhost',
  String[1]                      $container_name = lookup('pulp3::in_one_container::container_name')|$k| { 'pulp' },
  Integer                        $max_retries    = 10,
  Integer                        $sleep_seconds  = 5,
  Optional[Sensitive[String[1]]] $admin_password = Sensitive.new(system::env('PULP3_ADMIN_PASSWORD').lest|| { 'admin' }),
  Optional[Enum[podman,docker]]  $runtime        = undef,
  Optional[String]               $runtime_exe    = undef,

) {
  if $runtime and $runtime_exe {
    $host = get_target($targets)
    $_runtime = $runtime
    $_runtime_exe = $runtime_exe
  } else {
    $host = run_plan('pulp3::in_one_container::get_host', 'targets' => $targets, 'runtime' => $runtime)
    $_runtime = $host.facts['pioc_runtime']
    $_runtime_exe = $host.facts['available_runtimes'][$_runtime]
  }

  $admin_reset_cmd = "/bin/sh -c '${_runtime_exe} exec ${container_name} bash -c \"pulpcore-manager reset-admin-password -p \$PULP3_ADMIN_PASSWORD\"'" # lint:ignore:140chars
  log::debug( "Running:\n\n\t${admin_reset_cmd}\n" )

  range(1, $max_retries).each |Integer $x| {
    log::info("Attempt ${x} of ${max_retries} to set the admin password")

    $cmd_result = run_command($admin_reset_cmd, $host, {
        '_env_vars'     => { 'PULP3_ADMIN_PASSWORD' => $admin_password.unwrap },
        '_catch_errors' => true
    })

    if $cmd_result.ok {
      return $cmd_result
    }
    else {
      log::error("Could not set admin password, sleeping ${sleep_seconds} seconds")
      run_command("sleep ${sleep_seconds}", $host)
    }

    if $x == $max_retries {
      return $cmd_result
    }
  }
}
