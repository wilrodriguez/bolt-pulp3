
# This is the structure of a simple plan. To learn more about writing
# Puppet plans, see the documentation: http://pup.pt/bolt-puppet-plans

# The summary sets the description of the plan that will appear
# in 'bolt plan show' output. Bolt uses puppet-strings to parse the
# summary and parameters from the plan.
# @summary UNIMPLEMENTED - DOES NOTHING USEFUL
# @param targets The targets to run on.
plan pulp3::rpm::repo (
  TargetSpec                     $targets        = "localhost",
  Stdlib::HTTPUrl                $pulp_server    = lookup('pulp3::server_url')|$k|{"http://localhost"},
  Stdlib::Port                   $pulp_port      = lookup('pulp3::server_port')|$k|{8080},
  String[1]                      $admin_username = lookup('pulp3::admin_username')|$k|{'admin'},
  Optional[Sensitive[String[1]]] $admin_password = Sensitive.new(system::env('PULP3_ADMIN_PASSWORD').lest||{'admin'}),
) {
  $host = get_target($targets)
  $request_url = "${pulp_server}:${pulp_port}/pulp/api/v3/repositories/rpm/rpm/"
  $basic_auth = Binary.new("${admin_username}:${admin_password.unwrap}", '%s')

  $api_result = run_task( 'http_request', $host, {
    'base_url' => $request_url,
    'headers'  => {
      'Authorization' => "Basic ${basic_auth}",
    }
  })
  debug::break()
  out::message("API request: '${request_url}'")
  $command_result = run_command('whoami', $targets)

  return $command_result
}
