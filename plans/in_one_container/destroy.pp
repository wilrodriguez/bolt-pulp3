# @summary Destroy a Pulp-in-one-container and (optionally) its volumes
# @param targets A single target to run on (the container host)
# @param container_name Name of target Docker/podman container
# @param container_image Target Docker/podman image
# @param runtime Container runtime executable to use (`undef` = autodetect)
# @param force
#   When `true`, skips confirmation prompt before destroying things
# @param volumes
#   When `true`, deletes local container volumes
plan pulp3::in_one_container::destroy (
  TargetSpec                    $targets         = 'localhost',
  String[1]                     $user            = system::env('USER'),
  String[1]                     $container_name  = lookup('pulp3::in_one_container::container_name')|$k| { 'pulp' },
  String[1]                     $container_image = lookup('pulp3::in_one_container::container_image')|$k| { 'pulp/pulp' },
  Optional[String]              $runtime         = undef,
  Boolean                       $force           = lookup('pulp3::in_one_container::destroy::force')|$k| { false },
  Boolean                       $volumes         = lookup('pulp3::in_one_container::destroy::volumes')|$k| { true },
) {
  $host = run_plan('pulp3::in_one_container::get_host',$targets)
  $_runtime = $host.facts['pioc_runtime']
  $_runtime_exe = $host.facts['available_runtimes'][$_runtime]

  if run_plan( 'pulp3::in_one_container::match_container', {
      'host'        => $host,
      'name'        => $container_name,
      'image'       => $container_image,
      'all'         => true,
      'runtime_exe' => $_runtime_exe
  }) {
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
    $rm_result = run_command("${_runtime_exe} container rm -f ${container_name}", $host)
  }
  else {
    out::message( "Cannot find container '${container_name}'" )
  }

  if $volumes {
    $_volume_rm_result = run_plan(
      'pulp3::in_one_container::volumes::destroy',
      {
        'host'           => $host,
        'runtime_exe'    => $_runtime_exe,
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
