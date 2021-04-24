# Load the gem
require 'pulpcore_client'
require 'pulp_rpm_client'

require 'yaml'

# For all options, see:
#
#    https://www.rubydoc.info/gems/pulpcore_client/PulpcoreClient/Configuration
#
PulpcoreClient.configure do |config|
  config.host = 'http://pulp.server:8082'
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
  config.host = 'http://pulp.server:8082'
  config.username = 'admin'
  config.password = 'admin'
  config.debugging = ENV['DEBUG'].to_s.match?(/yes|true|1/i)
end



def wait_for_task_to_complete( task, opts={} )
  opts = { sleep_time: 10 }.merge(opts)
  tasks_api = PulpcoreClient::TasksApi.new

  # Wait for sync task to complete
  while tasks_api.read(task).state != 'completed' do
    task_info = tasks_api.read(task)
    puts " ...Waiting for task '#{task_info.name}' to complete (status: '#{task_info.state})'"
    warn "      ( pulp_href: #{task_info.pulp_href} )"
  ###        require 'pry'; binding.pry; opts[:sleep_time] = 0
    sleep opts[:sleep_time]
  end

  tasks_api
end


def wait_for_create_task_to_complete( task, opts={} )
  opts = { min_expected_resources: 1, max_expected_resources: 1 }.merge(opts)
  tasks_api = wait_for_task_to_complete( task, opts )

  created_resources = nil
  begin
    created_resources = tasks_api.read(task).created_resources
  rescue NameError => e
    warn e
    warn e.backtrace
    require 'pry'; binding.pry
  end

  if opts[:min_expected_resources] > 0 && created_resources.empty?
    warn "WARNING: sync task created 0 resources (task: '#{sync_async_info.task}')"
  end

  if created_resources.size > opts[:max_expected_resources]
    n = created_resources.size
    warn "WARNING: sync task created #{n} resources (task: '#{sync_async_info.task}')"
    warn "As far as we know, the task should only return 1.  So, check it out with pry!"
    require 'pry'; binding.pry
  end

  created_resources
end


def create_rpm_repo_mirror(name, remote_url)
  repos_api         = PulpRpmClient::RepositoriesRpmApi.new
  remotes_api       = PulpRpmClient::RemotesRpmApi.new
  repo_versions_api = PulpRpmClient::RepositoriesRpmVersionsApi.new
  publications_api  = PulpRpmClient::PublicationsRpmApi.new
  distributions_api = PulpRpmClient::DistributionsRpmApi.new

  opts={}
  result = nil
  begin
    # create repo
    rpm_rpm_repository = PulpRpmClient::RpmRpmRepository.new(name: name)
    repos_data = repos_api.create(rpm_rpm_repository, opts)
    puts repos_data.to_hash.to_yaml

    # create remote
    rpm_rpm_remote = PulpRpmClient::RpmRpmRemote.new(
      name: name,
      url: remote_url,
      policy: 'on_demand',
      #policy: 'immediate',
      tls_validation: false
    )

    remotes_data = remotes_api.create(rpm_rpm_remote, opts)

    # Set up sync
    # https://www.rubydoc.info/gems/pulp_rpm_client/PulpRpmClient/RpmRepositorySyncURL
    rpm_repository_sync_url = PulpRpmClient::RpmRepositorySyncURL.new(
      remote: remotes_data.pulp_href,
      mirror: true,
    )
    sync_async_info = repos_api.sync( repos_data.pulp_href, rpm_repository_sync_url )


    # Validate everything has gone as planned, then get the created resource
    created_resources = wait_for_create_task_to_complete( sync_async_info.task )
    rpm_rpm_repository_version_href = created_resources.first

    # get Repository Version
    repo_version_data = repo_versions_api.read(rpm_rpm_repository_version_href)

    # Create Publication
    rpm_rpm_publication = PulpRpmClient::RpmRpmPublication.new(
     repository_version: repo_version_data.pulp_href,
     metadata_checksum_type: 'sha256',
    )
    pub_sync_info = publications_api.create(rpm_rpm_publication, opts)
    pub_created_resources = wait_for_create_task_to_complete( pub_sync_info.task )
    pub_href = pub_created_resources.first

    # Create Distribution
    rpm_rpm_distribution = PulpRpmClient::RpmRpmDistribution.new(
      name: name,
      base_path: name,
      publication: pub_href,
    )
    dist_sync_info = distributions_api.create(rpm_rpm_distribution)
    dist_created_resources = wait_for_create_task_to_complete( dist_sync_info.task )
    dist_href = dist_created_resources.first
    distribution_data = distributions_api.list({base_path: name})

  ###  require 'pry'; binding.pry

  rescue PulpcoreClient::ApiError => e
    puts "Exception when calling API: #{e}"
    require 'pry'; binding.pry
  end
end



def delete_rpm_repo_mirror(name, remote_url)
  repos_api         = PulpRpmClient::RepositoriesRpmApi.new
  remotes_api       = PulpRpmClient::RemotesRpmApi.new
  tasks_api         = PulpcoreClient::TasksApi.new
  repo_versions_api = PulpRpmClient::RepositoriesRpmVersionsApi.new
  publications_api  = PulpRpmClient::PublicationsRpmApi.new
  distributions_api = PulpRpmClient::DistributionsRpmApi.new

  opts={}
  result = nil
  async_responses = []
  begin

    # delete repo
    repos_list = repos_api.list(name: name)
    if repos_list.count > 0
      repos_list.results.each do |repo_data|
        warn "!! DELETING repo #{repo_data.name}: #{repo_data.pulp_href}"
        async_response_data, response, headers = repos_api.delete_with_http_info(repo_data.pulp_href)
        async_responses << async_response_data if async_response_data
        #repo_versions_api.delete(repo_data.versions_href) unless repo_data.versions_href.empty?
      end
    end

    # delete remote
    remotes_list = remotes_api.list(name: name)
    if remotes_list.count > 0
      remotes_list.results.each do |remote_data|
        warn "!! DELETING remote #{remote_data.name}: #{remote_data.pulp_href}"
        async_response_data, response, headers = remotes_api.delete_with_http_info(remote_data.pulp_href)
        async_responses << async_response_data if async_response_data
      end
    end

    # delete publication
    publications_list = publications_api.list(name: name)
    if publications_list.count > 0
      publications_list.results.each do |publication_data|
        warn "!! DELETING publication: #{publication_data.pulp_href}"
        async_response_data, response, headers = publications_api.delete_with_http_info(publication_data.pulp_href)
        async_responses << async_response_data if async_response_data
      end
    end

    # delete distribution
    distributions_list = distributions_api.list(name: name)
    if distributions_list.count > 0
      distributions_list.results.each do |distribution_data|
        warn "!! DELETING distribution #{distribution_data.name}: #{distribution_data.pulp_href}"
        async_response_data, response, headers = distributions_api.delete_with_http_info(distribution_data.pulp_href)
        async_responses << async_response_data if async_response_data
      end
    end

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

def pry_rpm_repo_mirror(name, remote_url)
  repos_api         = PulpRpmClient::RepositoriesRpmApi.new
  remotes_api       = PulpRpmClient::RemotesRpmApi.new
  repo_versions_api = PulpRpmClient::RepositoriesRpmVersionsApi.new
  publications_api  = PulpRpmClient::PublicationsRpmApi.new
  distributions_api = PulpRpmClient::DistributionsRpmApi.new

  rpm_rpm_repository = PulpRpmClient::RpmRpmRepository.new(name: name)
  rpm_rpm_remote = PulpRpmClient::RpmRpmRemote.new(
    name: name,
    url: remote_url,
    policy: 'on_demand',
    tls_validation: false
  )

  begin
    require 'pry'; binding.pry
  rescue PulpcoreClient::ApiError => e
    puts "Exception when calling API: #{e}"
    require 'pry'; binding.pry
  end
end

repos_to_mirror = {
 #'iso_appstream' => 'file:///run/ISOs/unpacked/CentOS-8.3.2011-x86_64-dvd1/AppStream/',
 'pulp-baseos' => 'http://mirror.centos.org/centos/8/BaseOS/x86_64/os/',
 'pulp-appstream' => 'http://mirror.centos.org/centos/8/AppStream/x86_64/os/',
 'pulp-epel' => 'https://download.fedoraproject.org/pub/epel/8/Everything/x86_64/',
 'pulp-epel-modular'  => 'https://dl.fedoraproject.org/pub/epel/8/Modular/x86_64/',
}

#repos_to_mirror.each { |name, url| pry_rpm_repo_mirror(name, url) }
repos_to_mirror.each { |name, url| delete_rpm_repo_mirror(name, url) }
repos_to_mirror.each { |name, url| create_rpm_repo_mirror(name, url) }
