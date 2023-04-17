# @summary Create settings.py on Pulp3 server
#
# @api private
#
# Details at https://pulpproject.org/pulp-in-one-container/
plan pulp3::in_one_container::create_settings (
  TargetSpec $host,
  String[1] $runtime_exe,
  String[1] $container_name,
  Stdlib::Port $container_port,
  Stdlib::HTTPUrl $host_baseurl = 'http://127.0.0.1', # $host.facts['fqdn']
  Stdlib::AbsolutePath $django_log = lookup('pulp3::in_one_container::django_log')|$k|{'/tmp/django-info.log'},
  String[1] $log_level = 'INFO',
) {

  $pulp_settings = @("SETTINGS"/n)
    CONTENT_ORIGIN='${host_baseurl}:${container_port}'
    ANSIBLE_API_HOSTNAME='${host_baseurl}:${container_port}'
    ANSIBLE_CONTENT_HOSTNAME='${host_baseurl}:${container_port}/pulp/content'
    TOKEN_AUTH_DISABLED=True
    ALLOWED_CONTENT_CHECKSUMS=['sha224', 'sha256', 'sha384', 'sha512', 'sha1', 'md5']
    ALLOWED_IMPORT_PATHS=['/run/ISOs/unpacked','/allowed_imports']
    LOGGING={
        'version': 1,
        'disable_existing_loggers': False,
        'formatters': {
            'console': {
                'format': '%(name)-12s %(levelname)-8s %(message)s'
            },
            'file': {
                'format': '%(asctime)s %(name)-12s %(levelname)-8s %(message)s'
            }
        },
        'handlers': {
            'console': {
                'level': '${log_level}',
                'class': 'logging.StreamHandler',
                'formatter': 'console'
            },
        },
        'loggers': {
            '': {
                'level': '${log_level}',
                'handlers': ['console']
            }
        }
    }
    | SETTINGS

  catch_errors() || {
    $tmp_container_out         = run_command("${runtime_exe} run -id --name ${container_name}_tmp --volume ${container_name}-settings:/pulp centos:8", $host)
    $create_settings_py_out    = run_command("(${runtime_exe} exec -i ${container_name}_tmp sh -c 'cat > /pulp/settings.py') << EOM\n${pulp_settings}\nEOM", $host)
    $destroy_tmp_container_out = run_command("${runtime_exe} rm -f ${container_name}_tmp", $host)
  }
}
