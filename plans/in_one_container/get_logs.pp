# @summary Copy Django logs from a running PIOC
#
#   Depending on your sudo configuration, you may need to run `bolt plan run`
#   with `--sudo-password-prompt`
#
# @param targets A single target to run on (the container host)
# @param container_name Name of target Docker/podman container
# @param container_image Target Docker/podman image
# @param runtime Container runtime executable to use (`undef` = autodetect)
# @param force
#   When `true`, skips confirmation prompt before destroying things
# @param volumes
#   When `true`, deletes local vol mounts (may require `--sudo-password-prompt`)
plan pulp3::in_one_container::destroy (
  TargetSpec                    $targets         = 'localhost',
  String[1]                     $user            = system::env('USER'),
  Stdlib::AbsolutePath          $container_root  = system::env('PWD'),
  String[1]                     $container_name  = lookup('pulp3::in_one_container::container_name')|$k|{'pulp'},
  String[1]                     $container_image = lookup('pulp3::in_one_container::container_image')|$k|{'pulp/pulp'},
  Optional[Enum[podman,docker]] $runtime         = undef,
  Boolean                       $force           = false,
  Boolean                       $volumes         = false,
) {
  $host = pulp3::in_one_container::get_host($targets)
}
  unless run_plan( 'pulp3::in_one_container::match_container', {
    'host'        => $host,
    'name'        => $container_name,
    'image'       => $container_image,
    'all'         => true,
    'runtime_exe' => $host.facts['pioc_runtime_exe']
  }){
    out::message( "Cannot find container '${container_name}'" )

  }
