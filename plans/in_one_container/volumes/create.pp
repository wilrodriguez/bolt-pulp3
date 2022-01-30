# @summary Ensure volumes exist for the pulp container and prepopulate as necessary
#
# @param volume_names
#   The Volumes to create
#
# @api private
#
# Details at https://pulpproject.org/pulp-in-one-container/
plan pulp3::in_one_container::volumes::create (
  TargetSpec $host,
  String[1] $runtime_exe,
  String[1] $container_name,
  Array[String[1]] $volume_names = [
    'containers',
    'pgsql',
    'run',
    'settings',
    'storage'
  ],
  Boolean $noop = false,
) {
  apply(
    $host,
    '_description' => 'Ensure volumes exist for pulp container',
    '_noop' => $noop,
    '_catch_errors' => false,
  ){
    $volume_names.each |String $volume_name| {
      $_vname = "${container_name}-${volume_name}"

      exec { "Create ${_vname}":
        command => "${runtime_exe} volume create ${_vname}",
        unless  => "${runtime_exe} volume inspect ${_vname}",
        path    => [
          '/bin',
          '/usr/bin'
        ]
      }
    }
  }



}
