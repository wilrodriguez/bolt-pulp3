# @summary Create local directories for Pulp-in-one-container
# @param host A single host to configure
# @private true
#
# Details at https://pulpproject.org/pulp-in-one-container/
plan pulp::in_one_container::validate_container_exe(
  TargetSpec $host = 'localhost',
  Boolean $apply_el7_docker_fixes,
  Optional[Enum[podman,docker]] $runtime = undef,
) {
  $available_runtime_exes = ['podman','docker'].map |$exe| {
    if run_command(
      "command -v \"$exe\"", $host, { '_catch_errors' => true }
    )[0].value['exit_code'] == 0 { $exe }
  }.filter |$x| { $x }

  # CentOS 7 (and EL7) must use docker instead of podman
  #
  #   https://pulpproject.org/pulp-in-one-container/#docker-on-centos-7
  if $apply_el7_docker_fixes {
    warning( "EL7 detected on ${host.name}; forcing container runtime to 'docker'")
    warning( "  See: https://pulpproject.org/pulp-in-one-container/#docker-on-centos-7" )
    $_runtime = 'docker'
  } else {
    $_runtime = $runtime ? {
      String  => $runtime,
      default => 'podman',
    }
  }
  unless $_runtime in $available_runtime_exes {
    fail_plan( "FATAL: The runtime executable '${_runtime}' is not available on '${host}'.  Make sure the correct container runtime is installed and configured." )
  }

  return( $_runtime )
}
