# @summary Destroy a Pulp-in-one-container
#
#   Depending on your sudo configuration, you may need to run `bolt plan run`
#   with `--sudo-password-prompt`
#
# @param targets A single target to run on (the container host)
plan pulp3::in_one_container::destroy (
  TargetSpec                    $targets         = "localhost",
  String[1]                     $user            = system::env('USER'),
  Stdlib::AbsolutePath          $container_root  = system::env('PWD'),
  String[1]                     $container_name  = lookup('pulp3::in_one_container::container_name')|$k|{'pulp'},
  String[1]                     $container_image = lookup('pulp3::in_one_container::container_image')|$k|{'pulp/pulp'},
  Stdlib::Port                  $container_port  = lookup('pulp3::in_one_container::container_port')|$k|{8080},
  Optional[Enum[podman,docker]] $runtime         = undef,
  Boolean                       $force           = false,
  Boolean                       $volumes         = false,
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

  if run_plan( 'pulp3::in_one_container::match_container', {
    'host'        => $host,
    'name'        => $container_name,
    'image'       => $container_image,
    'all'         => true,
    'runtime_exe' => $runtime_exe
  }){
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
  else {
    out::message( "Cannot find container '${container_name}'" )
  }

  if $volumes {
    $_volume_rm_result = run_plan(
      'pulp3::in_one_container::volumes::destroy',
      {
        'host'           => $host,
        'runtime_exe'    => $runtime_exe,
        'container_name' => $container_name
      }
    )
  }
  else {
    out::message('Skipping removal of volumes (enable with `volumes=true`')
    out::message('Exiting plan...')
    return undef
  }
}
