# @summary Manage a Pulp-in-one-container
# @param targets A single target to run on (the container host)
# @api private
plan pulp3::in_one_container::get_host (
  TargetSpec           $targets         = "localhost",
  String[1]            $container_name  = lookup('pulp3::in_one_container::container_name')|$k|{'pulp'},
  Optional[Enum[podman,docker]] $runtime = undef,
) {
  $host = get_target($targets)
  run_plan('facts', 'targets' => $host)

  $apply_el7_docker_fixes = (
    $host.facts['os']['family'] == 'Redhat' and
    $host.facts['os']['release']['major'] == '7'
  )

  $runtime_exe = run_plan(
    'pulp3::in_one_container::validate_container_exe',
    {
      'host'                   => $host,
      'apply_el7_docker_fixes' => $apply_el7_docker_fixes,
      'runtime'                => $runtime,
    }
  )

  $host.add_facts({
    'pioc_apply_el7_docker_fixes' => $apply_el7_docker_fixes,
    'pioc_runtime_exe'            => $runtime_exe,
  })

  return $host
}

