# @summary Destroy pulp container volumes
#
# @param volume_names
#   The Volumes to destroy
#
# @private true
#
# Details at https://pulpproject.org/pulp-in-one-container/
plan pulp3::in_one_container::volumes::destroy (
  TargetSpec $host,
  String[1] $runtime_exe,
  Array[String[1]] $volume_names = [
    'pulp-containers',
    'pulp-pgsql',
    'pulp-run',
    'pulp-settings',
    'pulp-storage'
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
      exec { "Destroy ${volume_name}":
        command => "${runtime_exe} volume rm ${volume_name}",
        onlyif => "${runtime_exe} volume inspect ${volume_name}",
        path    => [
          '/bin',
          '/usr/bin'
        ]
      }
    }
  }
}
