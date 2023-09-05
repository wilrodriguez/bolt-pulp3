# @summary Ensures a TargetSpec is a run-ready PIOC host Target with new fact
#   `pioc_runtime` ('docker' or 'podman') and `available_runtimes` (Hash of all
#   available container runtimes on the host, mapped to their executable paths)
# @return Target  a single host Target, with facts
# @api private
#
# @param targets  A single target to run on (the container host)
plan pulp3::in_one_container::get_host (
  TargetSpec                    $targets = 'localhost',
  Optional[Enum[podman,docker]] $runtime = undef,
) {
  $host = get_target($targets)
  run_plan('facts', 'targets' => $host)

  $available_runtime_exes = ['podman','docker'].reduce({}) |Hash $memo, String $exe| {
    $_runtime_check = run_command("command -v '${exe}'", $host,
      '_catch_errors' => true,
    )
    if $_runtime_check[0].value['exit_code'] == 0 {
      $new_memo = $memo + { $exe => strip($_runtime_check[0].value['stdout']) }
    } else {
      $new_memo = $memo
    }
    $new_memo
  }

  # CentOS 7 (and EL7) must use docker instead of podman
  #
  #   https://pulpproject.org/pulp-in-one-container/#docker-on-centos-7
  if (
    $host.facts['os']['family'] == 'Redhat' and
    $host.facts['os']['release']['major'] == '7'
  ) {
    warning( "EL7 detected on ${host.name}; forcing container runtime to 'docker'")
    warning( '  See: https://pulpproject.org/pulp-in-one-container/#docker-on-centos-7' )
    $_runtime = 'docker'
  } else {
    $_runtime = $runtime ? {
      String  => $runtime,
      default => 'podman',
    }
  }
  unless $_runtime in $available_runtime_exes.keys() {
    fail_plan( "FATAL: The container runtime executable '${_runtime}' is not available on '${host}'.  Make sure the correct container runtime is installed and configured." ) # lint:ignore:140chars
  }

  $host.add_facts(
    {
      'pioc_runtime'       => $_runtime,
      'available_runtimes' => $available_runtime_exes,
    }
  )

  return $host
}
