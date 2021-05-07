# Load the gem
require 'pulpcore_client'
require 'pulp_rpm_client'

require 'yaml'

###PULP_HOST='http://pulp.server:8082'
PULP_HOST="http://localhost:#{ENV['PULP_PORT'] || 8080}"

# For all options, see:
#
#    https://www.rubydoc.info/gems/pulpcore_client/PulpcoreClient/Configuration
#
PulpcoreClient.configure do |config|
  config.host = PULP_HOST
  config.username = 'admin'
  config.password = 'admin'
  # config.debugging = true
  # config.logger =  # Defines the logger used for debugging.
end


# https://www.rubydoc.info/gems/pulp_rpm_client/3.10.0

# For all options, see:
#
#    https://www.rubydoc.info/gems/pulp_rpm_client/PulpRpmClient/Configuration
#
PulpRpmClient.configure do |config|
  config.host = PULP_HOST
  config.username = 'admin'
  config.password = 'admin'
  config.debugging = ENV['DEBUG'].to_s.match?(/yes|true|1/i)
end

REPOS_API           = PulpRpmClient::RepositoriesRpmApi.new
REMOTES_API         = PulpRpmClient::RemotesRpmApi.new
REPO_VERSIONS_API   = PulpRpmClient::RepositoriesRpmVersionsApi.new
PUBLICATIONS_API    = PulpRpmClient::PublicationsRpmApi.new
DISTRIBUTIONS_API   = PulpRpmClient::DistributionsRpmApi.new
TASKS_API           = PulpcoreClient::TasksApi.new
CONTENT_PACKAGE_API = PulpRpmClient::ContentPackagesApi.new
RPM_COPY_API        = PulpRpmClient::RpmCopyApi.new

def wait_for_task_to_complete( task, opts={} )
  opts = { sleep_time: 10 }.merge(opts)

  # Wait for sync task to complete
  while !['completed','failed'].any?{ |state| TASKS_API.read(task).state == state }
    task_info = TASKS_API.read(task)
    puts "#{Time.now} ...Waiting for task '#{task_info.name}' to complete (status: '#{task_info.state})'"
    warn "      ( pulp_href: #{task_info.pulp_href} )"
    sleep opts[:sleep_time]
  end
end


def wait_for_create_task_to_complete( task, opts={} )
  opts = { min_expected_resources: 1, max_expected_resources: 1 }.merge(opts)
  wait_for_task_to_complete( task, opts )

  created_resources = nil
  begin
    created_resources = TASKS_API.read(task).created_resources
  rescue NameError => e
    warn e
    warn e.backtrace
    require 'pry'; binding.pry
  end

  if opts[:min_expected_resources] > 0 && created_resources.empty?
    warn "WARNING: sync task created 0 resources (task: '#{task}')"
  end

  if created_resources.size > opts[:max_expected_resources]
    n = created_resources.size
    warn "WARNING: sync task created #{n} resources (task: '#{task}')"
    warn "As far as we know, the task should only return 1.  So, check it out with pry!"
    require 'pry'; binding.pry
  end

  created_resources
end


def idempotently_create_rpm_repo(name, labels={}, opts={})
  repos_data = nil
  repos_list = REPOS_API.list(name: name)
  if repos_list.count > 0
    warn "WARNING: repo '#{name}' already exists!"
    repos_data = repos_list.results[0]
  else
    rpm_rpm_repository = PulpRpmClient::RpmRpmRepository.new(name: name, pulp_labels: labels)
    repos_data = REPOS_API.create(rpm_rpm_repository, opts)
  end
  puts repos_data.to_hash.to_yaml
  repos_data
end

def create_rpm_repo_mirror(name, remote_url, labels={})
  # create remote
  rpm_rpm_remote = PulpRpmClient::RpmRpmRemote.new(
    name: name,
    url: remote_url,
    policy: 'on_demand', #policy: 'immediate',
    tls_validation: false
  )

  remotes_data = REMOTES_API.create(rpm_rpm_remote, opts)

  # Set up sync
  # https://www.rubydoc.info/gems/pulp_rpm_client/PulpRpmClient/RpmRepositorySyncURL
  rpm_repository_sync_url = PulpRpmClient::RpmRepositorySyncURL.new(
    remote: remotes_data.pulp_href,
    mirror: true,
  )
  sync_async_info = REPOS_API.sync( repos_data.pulp_href, rpm_repository_sync_url )

  created_resources = wait_for_create_task_to_complete( sync_async_info.task )
  created_resources.first
end


def idempotently_create_rpm_publication(rpm_rpm_repository_version_href, labels={})
  result = nil
  begin
    list = PUBLICATIONS_API.list(repository_version: rpm_rpm_repository_version_href)
    if list.count > 0
      warn "WARNING: publication for '#{rpm_rpm_repository_version_href}' already exists!"
      return list.results.first
    end
    # Create Publication
    rpm_rpm_publication = PulpRpmClient::RpmRpmPublication.new(
     repository_version: rpm_rpm_repository_version_href,
     metadata_checksum_type: 'sha256',
    )
    pub_sync_info = PUBLICATIONS_API.create(rpm_rpm_publication)
    pub_created_resources = wait_for_create_task_to_complete( pub_sync_info.task )
    result = pub_created_resources.first
  rescue PulpcoreClient::ApiError, PulpRpmClient::ApiError => e
    puts "Exception when calling API: #{e}"
      warn "===> #{e}\n\n#{e.backtrace.join("\n").gsub(/^/, '    ')}\n\n==> INVESTIGATE WITH PRY"
    require 'pry'; binding.pry
  end
  result
end


def idempotently_create_rpm_distro(name, pub_href, labels={})
  result = nil
  begin
    list = DISTRIBUTIONS_API.list(name: name)
    if list.count > 0
      warn "WARNING: distro '#{name}' already exists!"
      return list.results.first
    end

    # Create Distribution
    rpm_rpm_distribution = PulpRpmClient::RpmRpmDistribution.new(
      name: name,
      base_path: name,
      publication: pub_href,
    )
    dist_sync_info = DISTRIBUTIONS_API.create(rpm_rpm_distribution)
    dist_created_resources = wait_for_create_task_to_complete( dist_sync_info.task )
    dist_href = dist_created_resources.first
    distribution_data = DISTRIBUTIONS_API.list({base_path: name})
    return( distribution_data.results.first )

  rescue PulpcoreClient::ApiError, PulpRpmClient::ApiError => e
    puts "Exception when calling API: #{e}"
      warn "===> #{e}\n\n#{e.backtrace.join("\n").gsub(/^/, '    ')}\n\n==> INVESTIGATE WITH PRY"
    require 'pry'; binding.pry
  end
  puts result.to_hash.to_yaml
  result
end



def delete_rpm_repo(name)
  async_responses = []
  repos_list = REPOS_API.list(name: name)
  if repos_list.count > 0
    repos_list.results.each do |repo_data|
      warn "!! DELETING repo #{repo_data.name}: #{repo_data.pulp_href}"
      async_response_data = REPOS_API.delete(repo_data.pulp_href)
      async_responses << async_response_data if async_response_data
      #REPO_VERSIONS_API.delete(repo_data.versions_href) unless repo_data.versions_href.empty?
    end
  end
  async_responses
end


def delete_rpm_remote(name)
  api = PulpRpmClient::RemotesRpmApi.new
  async_responses = []
  list = api.list(name: name)
  if list.count > 0
    list.results.each do |data|
      warn "!! DELETING remote #{data.name}: #{data.pulp_href}"
      async_response_data = api.delete(data.pulp_href)
      async_responses << async_response_data if async_response_data
    end
  end

  async_responses
end

def delete_rpm_publication(name)
  publication_href = nil
  async_responses = []

  distributions_list = DISTRIBUTIONS_API.list(name: name)
  return [] unless  distributions_list.count > 0

  publication_href = distributions_list.results.first.publication
  return [] unless publication_href

  publications_list = PUBLICATIONS_API.list(name: name)
  return [] unless  publications_list.count > 0

  publications_list.results.each do |publication_data|
    warn "!! DELETING publication: (#{name}) #{publication_data.pulp_href}"
    async_response_data = PUBLICATIONS_API.delete(publication_href)
    async_responses << async_response_data if async_response_data
  end

  async_responses
end

def delete_rpm_distribution(name)
  async_responses = []

  # delete distribution
  distributions_list = DISTRIBUTIONS_API.list(name: name)

  if distributions_list.count > 0
    distributions_list.results.each do |distribution_data|
      warn "!! DELETING distribution #{distribution_data.name}: #{distribution_data.pulp_href}"
      async_response_data = DISTRIBUTIONS_API.delete(distribution_data.pulp_href)
      async_responses << async_response_data if async_response_data
    end
  end

  async_responses
end


def delete_rpm_repo_mirror(name, remote_url)
  async_responses = []

  begin
    # queue up deletion tasks
    # NOTE errors out the first time through; is something triggering a cascading delete?
    async_responses += delete_rpm_repo(name)
    async_responses += delete_rpm_remote(name)
    async_responses += delete_rpm_publication(name)
    async_responses += delete_rpm_distribution(name)

    # Wait for all deletion tasks to complete
    async_responses.each do |delete_async_info|
      next unless delete_async_info
      @delete_async_info = delete_async_info
      wait_for_task_to_complete( delete_async_info.task )
    end

  rescue PulpcoreClient::ApiError => e
    puts "Exception when calling API: #{e}"
    require 'pry'; binding.pry
  end
end

def get_rpm_distro(name)
  distributions_list = DISTRIBUTIONS_API.list(name: name)
  if distributions_list.count > 0
    return distributions_list.results.first
  end
  raise "Could not find distribution '#{name}'"
end

def get_repo_version_from_distro(name)
  distribution = get_rpm_distro(name)
  publication_href = distribution.publication
  raise "No publication found for distribution '#{name}'" unless publication_href

  publication = PUBLICATIONS_API.read(publication_href)
  repo_versions = REPO_VERSIONS_API.read( publication.repository_version )
  repo_versions
end

def get_rpm_hrefs(repo_version_href,rpms)

  paginated_package_response_list = CONTENT_PACKAGE_API.list({:name__in => rpms, :repository_version => repo_version_href })
  # FIXME TODO follow pagination, if necessary (ugh)
  # FIXME TODO check that all rpms were returned
  rpm_hrefs = paginated_package_response_list.results.map{|x| x.pulp_href }
  rpm_hrefs
end

def advanced_rpm_copy(repos_to_mirror)
  config = []
  repos_to_mirror.each do |name, data|
    config << {
      'source_repo_version' => data[:source_repo_version_href],
      'dest_repo'           => data[:dest_repo_href],
      'content'             => data[:rpm_hrefs],
    }
  end

  begin
    copy = PulpRpmClient::Copy.new({
      config: config,
      dependency_solving: true,
    })

    async_response = RPM_COPY_API.copy_content(copy)
    wait_for_task_to_complete( async_response.task )
    return async_response.task
  rescue PulpcoreClient::ApiError => e
    puts "Exception when calling API: #{e}"
    require 'pry'; binding.pry
  end
end


repos_to_mirror_file = 'repos_to_mirror.yaml'
repos_to_mirror = YAML.load_file(repos_to_mirror_file)
File.open('_repos_to_mirror.yaml','w'){ |f| f.puts repos_to_mirror.to_yaml }

mirror_distros = {}
slim_repos = {}


CREATE_NEW, USE_EXISTING = 1 , 2
action = USE_EXISTING
action = CREATE_NEW if (ARGV.first == 'create' || ARGV.first == 'recreate')
if action == CREATE_NEW
  # TODO use these labels to identify repo purpose for cleanup/creation
  labels = {
    'simpbuild' => 'testbuild-1',
    'reporole'  => 'remote_mirror',
  }
  repos_to_mirror.each { |name, data| delete_rpm_repo_mirror(name, data[:url]) }
  repos_to_mirror.each do |name, data|
    repo = idempotently_create_rpm_repo(name , labels)
    rpm_rpm_repository_version_href = create_rpm_repo_mirror(name, remote_url, labels={})
    pub_href = idempotently_create_rpm_publication(rpm_rpm_repository_version_href, labels)
    mirror_distros[name] = idempotently_create_rpm_distro(name, pub_href)
  end
  #  TODO: do everything that's in USE_EXISTING, too
elsif action == USE_EXISTING
  labels = {
    'simpbuild' => 'testbuild-1',
    'reporole'  => 'slim_mirror',
  }

  repos_to_mirror.each do |name, data|
    repo_version_href = get_repo_version_from_distro(name).pulp_href
    repos_to_mirror[name][:source_repo_version_href] = repo_version_href
    repos_to_mirror[name][:rpm_hrefs] = get_rpm_hrefs(repo_version_href, data[:rpms])
    slim_repo_name = name.sub(/^pulp\b/, 'simpbuild-6.6.0' ) # TODO: use dynamic names/labels
    repo = idempotently_create_rpm_repo(slim_repo_name, labels)
    slim_repos[slim_repo_name] ||= {}
    slim_repos[slim_repo_name][:pulp_href] = repo.pulp_href
    slim_repos[slim_repo_name][:source_repo_name] = name
    repos_to_mirror[name][:dest_repo_href] = repo.pulp_href
  end
  copy_task = advanced_rpm_copy(repos_to_mirror)

  slim_repos.each do |name, data|
    rpm_rpm_repository_version_href = REPOS_API.read(data[:pulp_href]).latest_version_href
    pub_href = idempotently_create_rpm_publication(rpm_rpm_repository_version_href, labels)
    distro = idempotently_create_rpm_distro(name, pub_href)
    slim_repos[name][:distro_href] = distro.pulp_href
    slim_repos[name][:distro_url] = distro.base_url
  end

  output_file = '_slim_repos.yaml'
  puts "Writing slim_repos information to #{output_file}..."
  File.open(output_file,'w'){ |f| f.puts slim_repos.to_yaml }
  puts 'FINIS'
end

