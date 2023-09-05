# @summary Determine if specified container already exists
# @api private
# @return Boolean true if container is found, false if not found
#
# @param host  The container host (usually localhost)
# @param all  When true, matches all (including stopped) containers
#
# Details at https://pulpproject.org/pulp-in-one-container/
plan pulp3::in_one_container::match_container(
  TargetSpec                        $host,
  Boolean                           $all         = false,
  String[1]                         $name        = lookup('pulp3::in_one_container::container_name')|$k| { 'pulp' },
  String[1]                         $image       = lookup('pulp3::in_one_container::container_image')|$k| { 'pulp/pulp' },
  Optional[Stdlib::Port]            $port        = undef,
  Optional[Enum['podman','docker']] $runtime     = $host.facts['pioc_runtime'],
  Optional[String[1]]               $runtime_exe = $host.facts['available_runtimes'][$runtime],
) {
  $extra_args  = $all ? { true => '-a', default => '' }

  $ls_result = run_command(
    "${runtime_exe} container ls ${extra_args} --format='{{.Names}}|{{.ID}}|{{.Image}}|{{.Ports}}'",
    $host,
  )

  $ls_nodes = Hash(
    $ls_result[0].value['stdout'].split("\n").map |$x| {
      $node_parts = $x.strip.split('\|')

      if $node_parts[3] {
        $node_ports = Integer($node_parts[3].split('->')[0].split(':')[-1])
      }
      else {
        $node_ports = undef
      }

      [
        $node_parts[0],
        {
          'id'    => $node_parts[1],
          'image' => $node_parts[2],
          'ports' => [$node_ports],
          'raw'   => $x.regsubst('\|','  ','G')
        }
      ]
    }
  )

  if $ls_nodes[$name] {
    if $ls_nodes[$name]['image'] == $image {
      if $port and !( $port in $ls_nodes[$name]['ports'] ) {
        fail_plan("Container '${name}' is in use but the port differs\n  ${ls_nodes[$name]['raw']}")
      }

      return true
    }
  }

  return false
}
