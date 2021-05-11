# TODO: use pulp labels to identify repo build session/purpose for cleanup/creation

require 'yaml'

PULP_HOST = "http://localhost:#{ENV['PULP_PORT'] || 8080}"

class Pulp3RpmMirrorSlimmer
  def initialize(
    build_name:,
    pulp_user: 'admin',
    pulp_password: 'admin'
  )
    @build_name = build_name
    @pulp_labels = {
      'simpbuildsession' => "#{build_name}-#{Time.now.strftime("%F")}",
    }

    require 'pulpcore_client'
    require 'pulp_rpm_client'

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

    @ReposAPI           = PulpRpmClient::RepositoriesRpmApi.new
    @RemotesAPI         = PulpRpmClient::RemotesRpmApi.new
    @RepoVersionsAPI = PulpRpmClient::RepositoriesRpmVersionsApi.new
    @PublicationsAPI    = PulpRpmClient::PublicationsRpmApi.new
    @DistributionsAPI   = PulpRpmClient::DistributionsRpmApi.new
    @TasksAPI           = PulpcoreClient::TasksApi.new
    @ContentPackageAPI = PulpRpmClient::ContentPackagesApi.new
    @RpmCopyAPI        = PulpRpmClient::RpmCopyApi.new
  end

  def wait_for_task_to_complete(task, opts = {})
    opts = { sleep_time: 10 }.merge(opts)

    # Wait for sync task to complete
    until %w[completed failed].any? { |state| @TasksAPI.read(task).state == state }
      task_info = @TasksAPI.read(task)
      puts "#{Time.now} ...Waiting for task '#{task_info.name}' to complete (status: '#{task_info.state})'"
      warn "      ( pulp_href: #{task_info.pulp_href} )"
      sleep opts[:sleep_time]
    end

    @TasksAPI.read(task)
  end

  def wait_for_create_task_to_complete(task, opts = {})
    opts = { min_expected_resources: 1, max_expected_resources: 1 }.merge(opts)
    task_result = wait_for_task_to_complete(task, opts)
    raise "Pulp3 ERROR: Task #{task} failed:\n\n#{task_result.error['description']}" if task_result.state == 'failed'

    created_resources = nil
    begin
      created_resources = @TasksAPI.read(task).created_resources
    rescue NameError => e
      warn e
      warn e.backtrace
      require 'pry'; binding.pry
    end

    if created_resources.empty? && opts[:min_expected_resources] > 0
      warn "WARNING: sync task created 0 resources (task: '#{task}')"
    end

    if created_resources.size > opts[:max_expected_resources]
      n = created_resources.size
      warn "WARNING: sync task created #{n} resources (task: '#{task}')"
      warn 'As far as we know, the task should only return 1.  So, check it out with pry!'
      require 'pry'; binding.pry
    end

    created_resources
  end

  def ensure_rpm_repo(name, labels = {}, opts = {})
    repos_data = nil
    repos_list = @ReposAPI.list(name: name)
    if repos_list.count > 0
      warn "WARNING: repo '#{name}' already exists!"
      repos_data = repos_list.results[0]
    else
      rpm_rpm_repository = PulpRpmClient::RpmRpmRepository.new(name: name, pulp_labels: labels)
      repos_data = @ReposAPI.create(rpm_rpm_repository, opts)
    end
    puts repos_data.to_hash.to_yaml
    repos_data
  end

  def create_rpm_repo_mirror(name, remote_url, repo, _labels = {})
    # create remote
    warn "-- creating remote #{name} from #{remote_url}"

    begin
      rpm_rpm_remote = PulpRpmClient::RpmRpmRemote.new(
        name: name,
        url: remote_url,
        policy: 'on_demand', # policy: 'immediate',
        tls_validation: false
      )

      remotes_data = @RemotesAPI.create(rpm_rpm_remote)

      # Set up sync
      # https://www.rubydoc.info/gems/pulp_rpm_client/PulpRpmClient/RpmRepositorySyncURL
      rpm_repository_sync_url = PulpRpmClient::RpmRepositorySyncURL.new(
        remote: remotes_data.pulp_href,
        mirror: true
      )
      sync_async_info = @ReposAPI.sync(repo.pulp_href, rpm_repository_sync_url)
    rescue PulpcoreClient::ApiError, PulpRpmClient::ApiError => e
      puts "Exception when calling API: #{e}"
      warn "===> #{e}\n\n#{e.backtrace.join("\n").gsub(/^/, '    ')}\n\n==> INVESTIGATE WITH PRY"
      require 'pry'; binding.pry
    end

    created_resources = wait_for_create_task_to_complete(sync_async_info.task)
require 'pry'; binding.pry unless created_resources.first
    created_resources.first
  end

  def ensure_rpm_publication(rpm_rpm_repository_version_href, labels = {})
    pub_href = nil
    begin
      list = @PublicationsAPI.list(repository_version: rpm_rpm_repository_version_href)
      if list.count > 0
        warn "WARNING: publication for '#{rpm_rpm_repository_version_href}' already exists!"
        return list.results.first
      end
      # Create Publication
      rpm_rpm_publication = PulpRpmClient::RpmRpmPublication.new(
        repository_version: rpm_rpm_repository_version_href,
        metadata_checksum_type: 'sha256'
      )
      pub_sync_info = @PublicationsAPI.create(rpm_rpm_publication)
      pub_created_resources = wait_for_create_task_to_complete(pub_sync_info.task)
      pub_href = pub_created_resources.first
    rescue PulpcoreClient::ApiError, PulpRpmClient::ApiError => e
      puts "Exception when calling API: #{e}"
      warn "===> #{e}\n\n#{e.backtrace.join("\n").gsub(/^/, '    ')}\n\n==> INVESTIGATE WITH PRY"
      require 'pry'; binding.pry
    end
     @PublicationsAPI.read( pub_href )
  end

  def ensure_rpm_distro(name, pub_href, labels = {})
    warn( "== ensure RPM distro #{name} for publication #{pub_href}")
    result = nil
    begin
      rpm_rpm_distribution = PulpRpmClient::RpmRpmDistribution.new(
        name: name,
        base_path: name,
        publication: pub_href
      )

      list = @DistributionsAPI.list(name: name)
      if list.count > 0
        distro = list.results.first
        if distro.publication == pub_href
          warn "WARNING: distro '#{name}' already exists with publication #{pub_href}!"
          return distro
        end
        warn "== Updating distro '#{name}'"
        dist_sync_info = @DistributionsAPI.update(distro.pulp_href, rpm_rpm_distribution)
        wait_for_task_to_complete(dist_sync_info.task)
        return @DistributionsAPI.list(name: name).results.first
      end

      # Create Distribution
      warn "== Creating distro '#{name}'"
      dist_sync_info = @DistributionsAPI.create(rpm_rpm_distribution)
      dist_created_resources = wait_for_create_task_to_complete(dist_sync_info.task)
      dist_href = dist_created_resources.first
      dist_href.inspect
      distribution_data = @DistributionsAPI.list({ base_path: name })
      return(distribution_data.results.first)
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
    repos_list = @ReposAPI.list(name: name)
    if repos_list.count > 0
      repos_list.results.each do |repo_data|
        warn "!! DELETING repo #{repo_data.name}: #{repo_data.pulp_href}"
        async_response_data = @ReposAPI.delete(repo_data.pulp_href)
        async_responses << async_response_data if async_response_data
        # @RepoVersionsAPI.delete(repo_data.versions_href) unless repo_data.versions_href.empty?
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

  def delete_rpm_publication_for_distro(distro_name)
    publication_href = nil
    async_responses = []

    distributions_list = @DistributionsAPI.list(name: distro_name)
    return [] unless distributions_list.count > 0

    publication_href = distributions_list.results.first.publication
    return [] unless publication_href

    begin
      warn "!! DELETING publication: (#{distro_name}) #{publication_href}"
      async_response_data = @PublicationsAPI.delete(publication_href)
      async_responses << async_response_data if async_response_data
    rescue PulpRpmClient::ApiError => e
      raise e unless (e.message =~ /HTTP status code: 404/)
    end

    async_responses
  end

  def delete_rpm_distribution(name)
    async_responses = []

    # delete distribution
    distributions_list = @DistributionsAPI.list(name: name)

    if distributions_list.count > 0
      distributions_list.results.each do |distribution_data|
        warn "!! DELETING distribution #{distribution_data.name}: #{distribution_data.pulp_href}"
        async_response_data = @DistributionsAPI.delete(distribution_data.pulp_href)
        async_responses << async_response_data if async_response_data
      end
    end

    async_responses
  end

  def delete_rpm_repo_mirror(name)
    async_responses = []

    begin
      # queue up deletion tasks
      # NOTE errors out the first time through; is something triggering a cascading delete?
      async_responses += delete_rpm_repo(name)
      async_responses += delete_rpm_remote(name)
      async_responses += delete_rpm_publication_for_distro(name)
      async_responses += delete_rpm_distribution(name)

      # Wait for all deletion tasks to complete
      async_responses.each do |delete_async_info|
        next unless delete_async_info

        @delete_async_info = delete_async_info
        wait_for_task_to_complete(delete_async_info.task)
      end
    rescue PulpcoreClient::ApiError => e
      puts "Exception when calling API: #{e}"
      require 'pry'; binding.pry
    end
  end

  def get_rpm_distro(name)
    distributions_list = @DistributionsAPI.list(name: name)
    return distributions_list.results.first if distributions_list.count > 0

    fail "Could not find distribution '#{name}'"
  end

  def get_repo_version_from_distro(name)
    distribution = get_rpm_distro(name)
    publication_href = distribution.publication
    fail "No publication found for distribution '#{name}'" unless publication_href

    publication = @PublicationsAPI.read(publication_href)
    @RepoVersionsAPI.read(publication.repository_version)
  end

  def get_rpm_hrefs(repo_version_href, rpms)
    limit = 100
    rpm_batch_size = limit
    results = []
    rpms.each_slice(rpm_batch_size).to_a.each do |rpm_names|
      offset = 0
      next_url = nil
      until offset > 0 && next_url.nil? do
        warn("Asking for #{rpm_names.size} RPM names (#{rpm_names.hash}) (offset: #{offset}), total results: #{results.size})")
        paginated_package_response_list = @ContentPackageAPI.list({
          name__in: rpm_names,
          repository_version: repo_version_href,
          # TODO is this reasonable?
          arch__in: ['noarch','x86_64'],
          fields: 'epoch,name,version,release,arch,pulp_href,location_href',
          limit: limit,
          offset: offset,
        })
        results += paginated_package_response_list.results
        offset += paginated_package_response_list.results.size
        require 'pry'; binding.pry if offset == 0
        next_url = paginated_package_response_list._next
      end
    end

    # Check that we found all rpms
    missing_names = rpms.uniq - results.map(&:name).uniq
    unless missing_names.empty?
      warn "WARNING: Mising #{missing_names.size} requested RPMs:\n  - #{missing_names.join("\n  - ")}\n\n"
      # FIXME TODO log this/return thi
      sleep 10
    end

    results.map { |x| x.pulp_href }
  end

  def advanced_rpm_copy(repos_to_mirror)
    config = []

    # Build API request body
    repos_to_mirror.each do |_name, data|
      config << {
        'source_repo_version' => data[:source_repo_version_href],
        'dest_repo' => data[:dest_repo_href],
        'content' => data[:rpm_hrefs]
      }
    end

    begin
      copy = PulpRpmClient::Copy.new({
        config: config,
        dependency_solving: true
      })

      async_response = @RpmCopyAPI.copy_content(copy)
      wait_for_task_to_complete(async_response.task)
      async_response.task
    rescue PulpcoreClient::ApiError => e
      puts "Exception when calling API: #{e}"
      require 'pry'; binding.pry
    end
  end

  def do_create_new(repos_to_mirror)
    # TODO: Safety check to only destroy repos if pulp labels are identical?
    pulp_labels = @pulp_labels.merge({ 'reporole' => 'remote_mirror' })

    repos_to_mirror.each do |name, data|
      delete_rpm_repo_mirror(name)
      delete_rpm_repo_mirror(name.sub(/^pulp\b/, @build_name))
    end
    repos_to_mirror.each do |name, data|
      repo = ensure_rpm_repo(name, pulp_labels)
      rpm_rpm_repository_version_href = create_rpm_repo_mirror(name, data['url'], repo, pulp_labels)
require 'pry'; binding.pry unless rpm_rpm_repository_version_href
      publication = ensure_rpm_publication(rpm_rpm_repository_version_href, pulp_labels)
      ensure_rpm_distro(name, publication.pulp_href)
    end
    do_use_existing(repos_to_mirror)
  end

  def do_use_existing(repos_to_mirror)
    pulp_labels = @pulp_labels.merge({ 'reporole' => 'slim_repo' })
    slim_repos = {}

    repos_to_mirror.each do |name, data|
      repo_version_href = get_repo_version_from_distro(name).pulp_href
      repos_to_mirror[name][:source_repo_version_href] = repo_version_href
      repos_to_mirror[name][:rpm_hrefs] = get_rpm_hrefs(repo_version_href, data['rpms'])

      slim_repo_name = name.sub(/^pulp\b/, @build_name)
      repo = ensure_rpm_repo(slim_repo_name, pulp_labels)
      slim_repos[slim_repo_name] ||= {}
      slim_repos[slim_repo_name][:pulp_href] = repo.pulp_href
      slim_repos[slim_repo_name][:source_repo_name] = name
      repos_to_mirror[name][:dest_repo_href] = repo.pulp_href
    end

require 'pry'; binding.pry
    copy_task = advanced_rpm_copy(repos_to_mirror)
    copy_task.inspect

    slim_repos.each do |name, data|
      rpm_rpm_repository_version_href = @ReposAPI.read(data[:pulp_href]).latest_version_href
      publication = ensure_rpm_publication(rpm_rpm_repository_version_href, pulp_labels)

      distro = ensure_rpm_distro(name, publication.pulp_href)
      slim_repos[name][:distro_href] = distro.pulp_href
      slim_repos[name][:distro_url] = distro.base_url
    end


    output_file = '_slim_repos.yaml'
    output_repo_file = File.basename( output_file, '.yaml' ) + '.repo'
    output_repo_script = File.basename( output_file, '.yaml' ) + '.sh'

    puts "\nWriting slim_repos data to: '#{output_file}"
    File.open(output_file, 'w') { |f| f.puts slim_repos.to_yaml }


    yum_repo_file_content = slim_repos.map do |k,v|
      result = <<~REPO_ENTRY
        [#{k}]
        enabled=1
        baseurl=#{v[:distro_url]}
        gpgcheck=0
        repo_gpgcheck=0
      REPO_ENTRY
       "#{result}\n"
    end
    puts "\nWriting slim_repos repo config to: '#{output_repo_file}"
    File.open(output_repo_file, 'w') { |f| f.puts yum_repo_file_content }

    dnf_mirror_cmd = <<~CMD_START
      # On EL7, ensure:
      #    yum install -y dnf dnf-plugins-core
      #
      # Useful EL8-only options: --remote-time --norepopath
      PATH_TO_LOCAL_MIRROR="$PWD/_download_path"
      mkdir -p "$PATH_TO_LOCAL_MIRROR"
      dnf reposync \\
        --download-metadata --downloadcomps \\
        --download-path "$PATH_TO_LOCAL_MIRROR" \\
        --setopt=reposdir=/dev/null \\
      CMD_START

    dnf_mirror_cmd += slim_repos.map { |k,v| "  --repofrompath #{k.sub("#{@build_name}-",'')},#{v[:distro_url]}" }.join(" \\\n")
    dnf_mirror_cmd += " \\\n" + slim_repos.map { |k,v| "  --repoid #{k.sub("#{@build_name}-",'')}" }.join(" \\\n")
    puts "\nWriting slim_repos repo config to: '#{output_repo_script}"
    File.open(output_repo_script, 'w') { |f| f.puts dnf_mirror_cmd }


    puts "\nSlim repos:",
      slim_repos.map{ |k,v| "    #{v[:distro_url]}" }.join("\n"), ''

    puts "\nYum repo file content:", yum_repo_file_content

  end

  def do(action:, repos_to_mirror_file:)
    repos_to_mirror = YAML.load_file(repos_to_mirror_file)

    if action == :create_new
      do_create_new(repos_to_mirror)
    elsif action == :use_existing
      do_use_existing(repos_to_mirror)
    end
  end
end

require 'optparse'

options = {
  action: :use_existing,
  repos_to_mirror_file: 'repos_to_mirror.yaml',
  pulp_label_session: 'testbuild-6.6.0',
  pulp_user: 'admin',
  pulp_password: 'admin',
}

OptsFilepath = String
OptsYAMLFilepath = Hash
OptionParser.new do |opts|
  opts.banner = 'Usage: do.rb [options]'

  opts.accept(OptsYAMLFilepath) do |path|
    File.exist?(path) || fail("Could not find specified file: '#{path}'")
    File.file?(path) || fail("Argument is not a file: '#{path}'")
    YAML.parse_file(path) # fails if not valid YAML
    path
  end

  opts.on(
    '-f', '--repos-rpms-file YAML_FILE', OptsYAMLFilepath,
    "YAML File with Repos/RPMs to include (#{options[:repos_to_mirror_file]})"
  ) do |f|
    options[:repos_to_mirror_file] = f
  end

  opts.on('-n', '--create-new', 'Delete existing + Create new repo mirrors') do |_v|
    options[:action] = :create_new
  end

  opts.on('-e', '--use-existing', 'Use existing repo mirrors') do |_v|
    options[:action] = :use_existing
  end

  opts.on(
    '-l', '--session-label LABEL',
    "Text for 'simpbuild' label on pulp entities ('#{options[:pulp_label_session]}')"
  ) do |text|
    options[:pulp_label_session] = text
  end

  opts.on('-v', '--[no-]verbose', 'Run verbosely') do |v|
    options[:verbose] = v
  end
end.parse!

puts options.to_yaml
p ARGV

mirror_slimmer = Pulp3RpmMirrorSlimmer.new(
  build_name: options[:pulp_label_session],
  pulp_user:     options[:pulp_user],
  pulp_password: options[:pulp_password],
)
mirror_slimmer.do(
  action:               options[:action],
  repos_to_mirror_file: options[:repos_to_mirror_file],
)

puts "\nFINIS"
