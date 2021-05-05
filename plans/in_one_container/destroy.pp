# @summary Destroy a Pulp-in-one-container
# @param targets A single target to run on (the container host)
plan pulp3::in_one_container::destroy (
  TargetSpec           $targets         = "localhost",
  String[1]            $user            = system::env('USER'),
  Stdlib::AbsolutePath $container_root  = system::env('PWD'),
  String[1]            $container_name  = lookup('pulp3::in_one_container::container_name')|$k|{'pulp'},
  String[1]            $container_image = lookup('pulp3::in_one_container::container_image')|$k|{'pulp/pulp'},
  Stdlib::Port         $container_port  = lookup('pulp3::in_one_container::container_port')|$k|{8080},
  Optional[Enum[podman,docker]] $runtime = undef,
  Boolean $force = false,
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

  $ls_a_result = run_command(
    "${runtime_exe} container ls -a --format='{{.Image}}  {{.ID}}  {{.Names}}'",
    $host,
  )
  unless $ls_a_result[0].value['stdout'].split("\n").any |$x| {
    $x.match("^${container_image}.*${container_name}$" )
  }{
    out::message( "Cannot find container '${container_name}'" )
    return false
  }

###  $ls_result = run_command(
###    "${runtime_exe} container ls --format='{{.Image}}  {{.ID}}  {{.Names}}'",
###    $host,
###  )
###  if $ls_result[0].value['stdout'].split("\n").any |$x| {
###    $x.match("^${container_image}.*${container_name}$")
###  }{
###    out::message( "Stopping container '${container_name}'..." )
###    $stop_result = run_command(
###      "${runtime_exe} container stop ${container_name}",
###      $host,
###    })
###  }

  unless $force {
    $confirm = prompt::menu(
      "Destroy container '${container_name}'?",
      ['yes','no'],
      'default' => 'no',
    )
    if $confirm == 'no' {
      out::message('Exiting plan...')
      return undef
    }
  }
  out::message( "Destroying container '${container_name}'..." )
  $rm_result = run_command("${runtime_exe} container rm -f ${container_name}", $host)
}
