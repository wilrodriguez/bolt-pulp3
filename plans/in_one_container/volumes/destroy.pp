# @summary Destroy pulp container volumes
#
# @param volume_names
#   The Volumes to destroy
#
# @api private
#
# Details at https://pulpproject.org/pulp-in-one-container/
plan pulp3::in_one_container::volumes::destroy (
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
    '_description' => 'Remove container volumes',
    '_noop' => $noop,
    '_catch_errors' => false,
  ){
    $volume_names.each |String $volume_name| {
      $_vname = "${container_name}-${volume_name}"

      exec { "Destroy ${_vname}":
        command => "${runtime_exe} volume rm ${_vname}",
        onlyif => "${runtime_exe} volume inspect ${_vname}",
        path    => [
          '/bin',
          '/usr/bin'
        ]
      }
    }
  }
}
