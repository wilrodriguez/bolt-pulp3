# @summary Ensure local directories and files for Pulp-in-one-container
# @param host A single host to configure
# @private true
#
# Details at https://pulpproject.org/pulp-in-one-container/
plan pulp::in_one_container::apply_local_filesystem (
  TargetSpec $host,
  Stdlib::AbsolutePath $container_root,
  Stdlib::Port $container_port,
  Array[Stdlib::AbsolutePath] $import_paths,
  Boolean $noop = false,
) {
  $apply_el7_docker_fixes = $host.facts['pioc_apply_el7_docker_fixes']
  return apply(
    $host,
    '_description' => "ensure directories exist in container root ($container_root)",
    '_noop' => $noop,
    '_catch_errors' => false,
  ){
    file{[
      'settings',
      'pulp_storage',
      'pgsql',
      'containers',
      'run',
    ].map |$x| { "${container_root}/${x}" }:
      ensure => directory,
    }

    # See https://pulpproject.org/pulp-in-one-container/#docker-on-centos-7
    #if $apply_el7_docker_fixes {
      file{[
        'run/postgresql',
        'run/pulpcore-resource-manager',
        'run/pulpcore-worker-1',
        'run/pulpcore-worker-2',
      ].map |$x| { "${container_root}/${x}" }:
        ensure => directory,
      }

      File["${container_root}/run/postgresql"]{ mode => 'a+w' }
    #}

    File["${container_root}/pgsql"]{ mode => 'a+w' }

    # TODO set up ALLOWED_IMPORT_PATHS via parameter
    file{ "${container_root}/settings/settings.py":
      content => @("SETTINGS"/n)
        CONTENT_ORIGIN='http://${host.facts['fqdn']}:${container_port}'
        ANSIBLE_API_HOSTNAME='http://${host.facts['fqdn']}:${container_port}'
        ANSIBLE_CONTENT_HOSTNAME='http://${host.facts['fqdn']}:${container_port}/pulp/content'
        TOKEN_AUTH_DISABLED=True
        ALLOWED_IMPORT_PATHS=['/run/ISOs/unpacked','/allowed_imports']
        | SETTINGS
    }
  }
}
