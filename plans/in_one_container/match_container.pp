# @summary Create local directories for Pulp-in-one-container
# @param host A single host to configure
# @private true
#
# Details at https://pulpproject.org/pulp-in-one-container/
plan pulp::in_one_container::match_container(
  TargetSpec $host,
  Boolean    $all = false,
  String[1]  $name  = lookup('pulp::in_one_container::container_name')|$k|{'pulp'},
  String[1]  $image = lookup('pulp::in_one_container::container_image')|$k|{'pulp/pulp'},
) {
  $extra_args  = $all ? { true => '-a', default => '' }
  $runtime_exe = $host.facts['pioc_runtime_exe']

  $ls_result = run_command(
    "${runtime_exe} container ls ${extra_args} --format='{{.Image}}  {{.ID}}  {{.Names}}'",
    $host,
  )
  if $ls_result[0].value['stdout'].split("\n").any |$x| {
    $x.match("^${image}.*${name}$")
  }{ return true }
  return false
}
