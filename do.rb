# Load the gem
require 'pulpcore_client'
require 'pulp_rpm_client'

require 'yaml'

PULP_HOST='http://pulp.server:8082'

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



def wait_for_task_to_complete( task, opts={} )
  opts = { sleep_time: 10 }.merge(opts)
  tasks_api = PulpcoreClient::TasksApi.new

  # Wait for sync task to complete
  while !['completed','failed'].any?{ |state| tasks_api.read(task).state == state }
    task_info = tasks_api.read(task)
    puts "#{Time.now} ...Waiting for task '#{task_info.name}' to complete (status: '#{task_info.state})'"
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
    return( distribution_data )

  ###  require 'pry'; binding.pry

  rescue PulpcoreClient::ApiError, PulpRpmClient::ApiError => e
    puts "Exception when calling API: #{e}"
      warn "===> #{e}\n\n#{e.backtrace.join("\n").gsub(/^/, '    ')}\n\n==> INVESTIGATE WITH PRY"
    require 'pry'; binding.pry
  end
end



def delete_rpm_repo(name)
  repos_api = PulpRpmClient::RepositoriesRpmApi.new
  async_responses = []
  repos_list = repos_api.list(name: name)
  if repos_list.count > 0
    repos_list.results.each do |repo_data|
      warn "!! DELETING repo #{repo_data.name}: #{repo_data.pulp_href}"
      async_response_data = repos_api.delete(repo_data.pulp_href)
      async_responses << async_response_data if async_response_data
      #repo_versions_api.delete(repo_data.versions_href) unless repo_data.versions_href.empty?
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
  distributions_api = PulpRpmClient::DistributionsRpmApi.new
  publications_api  = PulpRpmClient::PublicationsRpmApi.new
  publication_href = nil
  async_responses = []

  distributions_list = distributions_api.list(name: name)
  return [] unless  distributions_list.count > 0

  publication_href = distributions_list.results.first.publication
  return [] unless publication_href

  publications_list = publications_api.list(name: name)
  return [] unless  publications_list.count > 0

  publications_list.results.each do |publication_data|
    warn "!! DELETING publication: (#{name}) #{publication_data.pulp_href}"
    async_response_data = publications_api.delete(publication_href)
    async_responses << async_response_data if async_response_data
  end

  async_responses
end

def delete_rpm_distribution(name)
  distributions_api = PulpRpmClient::DistributionsRpmApi.new
  async_responses = []

  # delete distribution
  distributions_list = distributions_api.list(name: name)

  if distributions_list.count > 0
    distributions_list.results.each do |distribution_data|
      warn "!! DELETING distribution #{distribution_data.name}: #{distribution_data.pulp_href}"
      async_response_data = distributions_api.delete(distribution_data.pulp_href)
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

def get_rpm_repo_mirror_distro(name, url)
  distributions_api = PulpRpmClient::DistributionsRpmApi.new

  distributions_list = distributions_api.list(name: name)
  if distributions_list.count > 0
    return distributions_list.results.first
  end
  raise "Could not find distribution '#{name}'"
end


def create_rpm_copy_dest_repo_from(distros)
  repos_api         = PulpRpmClient::RepositoriesRpmApi.new
  remotes_api       = PulpRpmClient::RemotesRpmApi.new
  repo_versions_api = PulpRpmClient::RepositoriesRpmVersionsApi.new
  publications_api  = PulpRpmClient::PublicationsRpmApi.new
  distributions_api = PulpRpmClient::DistributionsRpmApi.new
  async_responses = []

  begin

require 'pry'; binding.pry


    # Wait for all tasks to complete
    async_responses.each do |async_info|
      next unless async_info
      @async_info = async_info
      wait_for_task_to_complete( async_info.task )
    end
require 'pry'; binding.pry

  rescue PulpcoreClient::ApiError => e
    puts "Exception when calling API: #{e}"
    require 'pry'; binding.pry
  end
end


#def pry_rpm_repo_mirror(name, remote_url)
#  repos_api         = PulpRpmClient::RepositoriesRpmApi.new
#  remotes_api       = PulpRpmClient::RemotesRpmApi.new
#  repo_versions_api = PulpRpmClient::RepositoriesRpmVersionsApi.new
#  publications_api  = PulpRpmClient::PublicationsRpmApi.new
#  distributions_api = PulpRpmClient::DistributionsRpmApi.new
#
#  rpm_rpm_repository = PulpRpmClient::RpmRpmRepository.new(name: name)
#  rpm_rpm_remote = PulpRpmClient::RpmRpmRemote.new(
#    name: name,
#    url: remote_url,
#    policy: 'on_demand',
#    tls_validation: false
#  )
#
#  begin
#    require 'pry'; binding.pry
#  rescue PulpcoreClient::ApiError => e
#    puts "Exception when calling API: #{e}"
#    require 'pry'; binding.pry
#  end
#end

repos_to_mirror = {
 # ISO
 'pulp-baseos' => {
   url: 'http://mirror.centos.org/centos/8/BaseOS/x86_64/os/',
   rpms: [
     'NetworkManager', # depends on baseos: NetworkManager-libnm, libndp
   ],
 },
 'pulp-appstream' => {
   url: 'http://mirror.centos.org/centos/8/AppStream/x86_64/os/',
   rpms: [
     '389-ds-base', # depends on lots of things from baseos: cracklib-dicts,selinux-policy +
   ],
 },
 # EPEL
 'pulp-epel' => {
   url: 'https://download.fedoraproject.org/pub/epel/8/Everything/x86_64/',
   rpms: [
     'htop',        # no deps
     'vim-ansible', # depends on appstream: vim-filesystem
   ],
 },
 'pulp-epel-modular'  => {
   url:'https://dl.fedoraproject.org/pub/epel/8/Modular/x86_64/',
   rpms: [

     '389-ds-base-legacy-tools', # depends on:
                                 #    baseos:       crypto-policies-scripts, libevent, perl-libs, +
                                 #    appstream:    python3-bind, nss, bind-libs, perl-Mozilla-LDAP +
                                 #  @ epel-modular: 389-ds-base-libs
                                 #
                                 # modularity info
                                 #    - only exists in 389-directory-server:stable (epel-modular)
                                 #

     '389-ds-base',              # depends on:
                                 #    baseos:       crypto-policies-scripts, libevent, perl-libs, +
                                 #    appstream:    python3-bind, nss, bind-libs, perl-Mozilla-LDAP +
                                 #  @ epel-modular: 389-ds-base-libs
                                 #
                                 # modularity info
                                 #  provided by:
                                 #    - 389-directory-server:stable (epel-modular)
                                 #    - 389-directory-server:stable (epel-modular)
                                 #    - 389-directory-server:stable (epel-modular)
                                 #    - 389-directory-server:stable (epel-modular)
                                 #
                                 #  depends on modules (:stable):
                                 #    perl:5.26, perl-IO-Socket-SSL:2.066, perl-libwww-perl:6.34

   ],
 },
}

mirror_distros = {}

#repos_to_mirror.each { |name, url| pry_rpm_repo_mirror(name, url) }


CREATE_NEW, USE_EXISTING = 1 , 2
action = USE_EXISTING
if action == CREATE_NEW
  repos_to_mirror.each { |name, data| delete_rpm_repo_mirror(name, data[:url]) }
  repos_to_mirror.each { |name, data| mirror_distros[name] = create_rpm_repo_mirror(name, data[:url]) }
  mirror_distros.each{ |name, distro| create_rpm_copy_dest_repo_from(distro) }
elsif action == USE_EXISTING

  repos_to_mirror.each { |name, data| mirror_distros[name] = get_rpm_repo_mirror_distro(name, data[:url]) }
  create_rpm_copy_dest_repo_from(mirror_distros)
  # get source repo_vers_href
  # get dest repo_vers_href
  # get content for each repo
  #
  # For each mirror:
  #   get source repo_version_href
  #   get dest repo_version_href
  #   get rpms for this mirror
  #
  # POST /pulp/api/v3/rpm/copy/
  #

end

