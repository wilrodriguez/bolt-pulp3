# TODO: use pulp labels to identify repo build session/purpose for cleanup/creation

require 'yaml'

PULP_HOST = "http://localhost:#{ENV['PULP_PORT'] || 8080}"

# Mirrors & copies RPMs from multiple repos into "slim" subset repositories,
#   including all RPM and modular dependencies.
#
# Pulp 3 documentation:
#
#  * Pulp 3 core:       https://docs.pulpproject.org/pulpcore/
#  * `pulp_rpm` Plugin: https://docs.pulpproject.org/pulp_rpm/
#
# REST APIs:
#
#  * https://docs.pulpproject.org/pulpcore/restapi.html
#  * https://docs.pulpproject.org/pulp_rpm/restapi.html
#
# RubyGem client APIs:
#
#   * https://www.rubydoc.info/gems/pulpcore_client/
#   * https://www.rubydoc.info/gems/pulp_rpm_client/
#
class Pulp3RpmMirrorSlimmer
  def initialize(
    build_name:,
    logger:,
    pulp_user: 'admin',
    pulp_password: 'admin'
  )
    @build_name = build_name
    @log = logger
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
      config.username = pulp_user
      config.password = pulp_password
      # config.debugging = true
      # config.logger =  # Defines the logger used for debugging.
    end


    # For all options, see:
    #
    #    https://www.rubydoc.info/gems/pulp_rpm_client/PulpRpmClient/Configuration
    #
    PulpRpmClient.configure do |config|
      config.host = PULP_HOST
      config.username = pulp_user
      config.password = pulp_password
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
      @log.info "#{Time.now} ...Waiting for task '#{task_info.name}' to complete (status: '#{task_info.state})'"
      @log.verbose "( pulp_href: #{task_info.pulp_href} )"
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
      @log.warn e
      @log.warn e.backtrace
      require 'pry'; binding.pry
    end

    if created_resources.empty? && opts[:min_expected_resources] > 0
      @log.warn "WARNING: sync task created 0 resources (task: '#{task}')"
    end

    if created_resources.size > opts[:max_expected_resources]
      n = created_resources.size
      @log.warn "WARNING: sync task created #{n} resources (task: '#{task}')"
      @log.warn 'As far as we know, the task should only return 1.  So, check it out with pry!'
      require 'pry'; binding.pry
    end

    created_resources
  end

  def ensure_rpm_repo(name, labels = {}, opts = {})
    repos_data = nil
    repos_list = @ReposAPI.list(name: name)
    if repos_list.count > 0
      @log.verbose "Repo '#{name}' already exists, moving on..."
      repos_data = repos_list.results[0]
    else
      rpm_rpm_repository = PulpRpmClient::RpmRpmRepository.new(name: name, pulp_labels: labels)
      repos_data = @ReposAPI.create(rpm_rpm_repository, opts)
    end
    @log.success("RPM repo '#{name}' exists")
    @log.debug repos_data.to_hash.to_yaml
    repos_data
  end

  def create_rpm_repo_mirror(name:, remote_url:, repo:, mirror_options: {}, pulp_labels: {})
    # create remote
    @log.info "Creating remote #{name} from #{remote_url}"

    remote_opts = {
      'name' => name,
      'url' => remote_url,
      'policy' => 'on_demand',
      #'pulp_labels' => pulp_labels,
      #'tls_validation' => false,
    }.merge( mirror_options )

    begin
      rpm_rpm_remote = PulpRpmClient::RpmRpmRemote.new(
        remote_opts.transform_keys(&:to_sym)
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
      @log.error "Exception when calling API: #{e}"
      @log.warn "===> #{e}\n\n#{e.backtrace.join("\n").gsub(/^/, '    ')}\n\n==> INVESTIGATE WITH PRY"
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
        @log.verbose "Publication for '#{rpm_rpm_repository_version_href}' already exists, moving on..."
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
      @log.error "Exception when calling API: #{e}"
      @log.warn "===> #{e}\n\n#{e.backtrace.join("\n").gsub(/^/, '    ')}\n\n==> INVESTIGATE WITH PRY"
      require 'pry'; binding.pry
    end
     @PublicationsAPI.read( pub_href )
  end

  def ensure_rpm_distro(name, pub_href, labels = {})
    @log.info( "== ensure RPM distro #{name} for publication #{pub_href}")
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
          @log.warn "WARNING: distro '#{name}' already exists with publication #{pub_href}!"
          return distro
        end
        @log.info "== Updating distro '#{name}'"
        dist_sync_info = @DistributionsAPI.update(distro.pulp_href, rpm_rpm_distribution)
        wait_for_task_to_complete(dist_sync_info.task)
        return @DistributionsAPI.list(name: name).results.first
      end

      # Create Distribution
      @log.info "== Creating distro '#{name}'"
      dist_sync_info = @DistributionsAPI.create(rpm_rpm_distribution)
      dist_created_resources = wait_for_create_task_to_complete(dist_sync_info.task)
      dist_href = dist_created_resources.first
      dist_href.inspect
      distribution_data = @DistributionsAPI.list({ base_path: name })
      return(distribution_data.results.first)
    rescue PulpcoreClient::ApiError, PulpRpmClient::ApiError => e
      @log.error "Exception when calling API: #{e}"
      @log.warn "===> #{e}\n\n#{e.backtrace.join("\n").gsub(/^/, '    ')}\n\n==> INVESTIGATE WITH PRY"
      require 'pry'; binding.pry
    end
    @log.success("RPM distro '#{name}' exists")
    @log.debug result.to_hash.to_yaml
    result
  end

  def delete_rpm_repo(name)
    async_responses = []
    repos_list = @ReposAPI.list(name: name)
    if repos_list.count > 0
      repos_list.results.each do |repo_data|
        @log.warn "!! DELETING repo #{repo_data.name}: #{repo_data.pulp_href}"
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
        @log.warn "!! DELETING remote #{data.name}: #{data.pulp_href}"
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
      @log.warn "!! DELETING publication: (#{distro_name}) #{publication_href}"
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
        @log.warn "!! DELETING distribution #{distribution_data.name}: #{distribution_data.pulp_href}"
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
      @log.error "Exception when calling API: #{e}"
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

  # We need a pulp href for each RPM, but Pulp's API returns every version for
  # a name.  We only want a a single RPM for each name:
  #
  #   - The best version (NEVRA) available
  #   - There may be contraints for particular packages (particular/max version)
  #     - (in which case: pick the best of what's left)
  #   - Assumptions:
  #     - If <name>.x86_64 exists, we don't also want <name>.i686
  #     - Not sure about <name>.x86_64 & <name>.noarch (does this happen?)
  def get_rpm_hrefs(repo_version_href, rpm_reqs)
    limit = 100
    rpm_batch_size = limit
    api_results = []
    results = []

    api_result_count = nil
    queried_rpms_count = 0

    # The API can only look for so many RPMs at a time, so query in batches
    rpm_reqs.each_slice(rpm_batch_size).to_a.each do |slice_of_rpms|
      @log.verbose("Querying RPMs by name, batch: #{queried_rpms_count+1}-#{queried_rpms_count+slice_of_rpms.size}")
      rpm_names = slice_of_rpms.map{|r| r['name']}
      queried_rpms_count += rpm_names.size
      offset = 0
      next_url = nil

      until offset > 0 && next_url.nil? do
        @log.verbose( "  pagination: #{offset}#{api_result_count ? ", total considered: #{offset}/#{api_result_count}" : ''} ")

        paginated_package_response_list = @ContentPackageAPI.list({
          name__in: rpm_names,
          repository_version: repo_version_href,
          # TODO is this reasonable?
          arch__in: ['noarch','x86_64','i686'],
          fields: 'epoch,name,version,release,arch,pulp_href,location_href',
          limit: limit,
          offset: offset,
          order: 'version',
        })
        api_results += paginated_package_response_list.results
        offset += paginated_package_response_list.results.size
        next_url = paginated_package_response_list._next
        api_result_count = paginated_package_response_list.count
      end
    end

    @log.verbose("Resolving constraints & best version for RPM from API results" )
    api_results.map(&:name).uniq.each do |rpm_name|
      rpm_req = rpm_reqs.select{|r| r['name'] == rpm_name }.first
      n_rpms = api_results.select{|r| r.name == rpm_name }
      n_results = []

      # filter candidates based on constraints
      if rpm_req['version']
        size = n_rpms.size
        n_rpms.select! do |r|
          # TODO: logic to compare release and epoch
          Gem::Dependency.new('', rpm_req['version']).match?('', Gem::Version.new(r.version))
        end
        # fail/@log.warn when no RPMs meet constraints
        raise "ERROR: No '#{rpm_name}' RPMs met the version constraint: '#{rpm_req['version']}' (#{size} considered)" if n_rpms.empty?
      end

      # find the best RPM for each arch
      n_rpms.map{|r| r.arch }.uniq.each do |arch|
        na_rpms = n_rpms.select{|r| r.arch == arch }

        # pick the best version (NEVR) for each arc
        nevr_rpms = na_rpms.sort do |a,b|
          next(a.epoch <=> b.epoch) unless ((a.epoch <=> b.epoch) == 0)
          next(a.version <=> b.version) unless ((a.version <=> b.version) == 0)
          a.release <=> b.release
        end
        n_results << nevr_rpms.last
      end

      # remove `<name>.i686` unless there is no `<name>.x86_64`
      if n_results.any?{|x| x.arch == 'i686' } && n_results.any?{|x| x.arch == 'x86_64' }
        @log.warn "WARNING: Ignoring #{rpm_name}.i686 because #{rpm_name}.x86_64 exists"
        n_results.reject!{|x| x.arch == 'i686' }
      end

      # This is still a weird case, so investigate it until we know what to expect
      if n_results.size > 1
        @log.warn "WARNING: RPMs for muliple arches found for '#{rpm_name}': #{n_results.map{|r| r.arch }.uniq.join(', ')}"
        sleep 1
        puts "Investigate this!"
        require 'pry'; binding.pry
      end

      results = n_results + results
    end

    # Check that we found all rpm_reqs
    missing_names = rpm_reqs.map{|r| r['name']}.uniq - results.map(&:name).uniq
    unless missing_names.empty?
      fail "\nFATAL: Repo was missing #{missing_names.size} requested RPMs:\n  - #{missing_names.join("\n  - ")}\n\n"
    end

    results.map { |x| x.pulp_href }
  end

  def advanced_rpm_copy(dest_repos)
    config = []

    # Build API request body
    dest_repos.each do |name, data|
      config << {
        'source_repo_version' => data[:source_repo_version_href],
        'dest_repo' => data[:pulp_href],
        'content' => data[:required_rpm_hrefs],
      }
    end

    begin
      @log.info "== Copying RPMs into slim Repo mirrors..."
      @log.verbose "Dest repos: #{dest_repos.keys.join(', ')}"
      @log.debug config.to_yaml
      copy = PulpRpmClient::Copy.new({
        config: config,
        dependency_solving: true
      })

      async_response = @RpmCopyAPI.copy_content(copy)
      wait_for_task_to_complete(async_response.task)

      task_result = wait_for_task_to_complete(async_response.task)
      raise PulpcoreClient::ApiError, "Pulp3 ERROR: Task #{async_response.task} failed:\n\n#{task_result.error['description']}" if task_result.state == 'failed'
      async_response.task
    rescue PulpRpmClient::ApiError, PulpcoreClient::ApiError => e
      @log.error "Exception when calling API: #{e}"
      require 'pry'; binding.pry
      raise e
    end
    @log.info "== Sucessfully copied RPMs+dependencies into dest repositories"
  end

  def delete_rpm_repo_mirrors(repos_to_mirror)
    repos_to_mirror.each do |name, data|
      delete_rpm_repo_mirror(name)
      delete_rpm_repo_mirror(name.sub(/^pulp\b/, @build_name))
    end
  end

  def do_create_new(repos_to_mirror)
    # TODO: Safety check to only destroy repos if pulp labels are identical?
    pulp_labels = @pulp_labels.merge({ 'reporole' => 'remote_mirror' })

    repos_to_mirror.each do |name, data|
      repo = ensure_rpm_repo(name, pulp_labels)
      rpm_rpm_repository_version_href = create_rpm_repo_mirror(
        name: name,
        remote_url: data['url'],
        repo: repo,
        mirror_options: data['mirror_options'] || {},
        pulp_labels: pulp_labels
      )
require 'pry'; binding.pry unless rpm_rpm_repository_version_href
      publication = ensure_rpm_publication(rpm_rpm_repository_version_href, pulp_labels)
      ensure_rpm_distro(name, publication.pulp_href)
    end
  end


  # Ensures slim repos exist for repos_to_mirror
  # @return [Hash] slim_repos data structure
  def slim_repos_for(repos_to_mirror)
    pulp_labels = @pulp_labels.merge({ 'reporole' => 'slim_repo' })
    slim_repos = {}

    repos_to_mirror.each do |name, data|
      @log.info("Ensuring slim repo mirror of '#{name}'")
      source_repo_version_href = get_repo_version_from_distro(name).pulp_href
      required_rpm_hrefs = get_rpm_hrefs(source_repo_version_href, data['rpms'])

      slim_repo_name = name.sub(/^pulp\b/, @build_name)
      repo = ensure_rpm_repo(slim_repo_name, pulp_labels)

      slim_repos[slim_repo_name] ||= {}
      slim_repos[slim_repo_name][:pulp_href] = repo.pulp_href
      slim_repos[slim_repo_name][:source_repo_name] = name
      slim_repos[slim_repo_name][:source_repo_version_href] = source_repo_version_href
      slim_repos[slim_repo_name][:required_rpm_hrefs] = required_rpm_hrefs
      @log.success("Slim repo mirror '#{slim_repo_name}' exists to copy from '#{name}'")
    end
    slim_repos
  end

  def do_use_existing(repos_to_mirror)
    pulp_labels = @pulp_labels.merge({ 'reporole' => 'slim_repo' })
    slim_repos = slim_repos_for(repos_to_mirror)

    # Slim RPM copy from all repos_to_mirror to all slim_repos
    copy_task = advanced_rpm_copy(slim_repos)
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

    @log.info "\nWriting slim_repos data to: '#{output_file}"
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
    @log.info "\nWriting slim_repos repo config to: '#{output_repo_file}"
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
    @log.info "\nWriting slim_repos repo config to: '#{output_repo_script}"
    File.open(output_repo_script, 'w') { |f| f.puts dnf_mirror_cmd }


    @log.info "\nSlim repos:\n" + \
      slim_repos.map{ |k,v| "    #{v[:distro_url]}" }.join("\n") + "\n"

    @log.info "\nYum repo file content:\n#{yum_repo_file_content.join("\n")}"

  end

  def do(action:, repos_to_mirror_file:)
    repos_to_mirror = YAML.load_file(repos_to_mirror_file)

    case action
    when :delete
      delete_rpm_repo_mirrors(repos_to_mirror)
    when :create_new
      delete_rpm_repo_mirrors(repos_to_mirror)
      do_create_new(repos_to_mirror)
      do_use_existing(repos_to_mirror)
    when :use_existing
      do_use_existing(repos_to_mirror)
    end
  end
end

OptsFilepath = String
OptsYAMLFilepath = Hash
def parse_options
  require 'optparse'

  options = {
    action: :use_existing,
    repos_to_mirror_file: nil,
    # FIXME: change/require?
    pulp_label_session: 'testbuild-6.6.0',
    pulp_user: 'admin',
    pulp_password: 'admin',
  }

  opts_parser = OptionParser.new do |opts|
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

    opts.on('-d', '--delete-existing', 'Delete existing mirrors & repos') do |_v|
      options[:action] = :delete
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
  end
  opts_parser.parse!

  unless options[:repos_to_mirror_file]
    warn '', 'ERROR: missing `--repos-rpms-file YAML_FILE` !', ''
    puts opts_parser.help
    exit 1
  end

  unless options[:repos_to_mirror_file]
    warn '', 'ERROR: missing `--repos-rpms-file YAML_FILE` !', ''
    puts opts_parser.help
    exit 1
  end

  options
end

def get_logger(log_file: 'rpm_mirror_slimmer.log')
  require 'logging'
  # Default logger
  Logging.init :debug, :verbose, :info, :happy, :warn, :success, :error, :recovery, :fatal

  # here we setup a color scheme called 'bright'
  Logging.color_scheme(
    'bright',
    lines: {
      debug: :blue,
      verbose: :blue,
      info: :cyan,
      happy: :magenta,
      warn: :yellow,
      success: :green,
      recovery: %i[black on_green],
      error: :red,
      fatal: %i[white on_red]
    },
    date: :gray,
    logger: :cyan,
    message: :magenta
  )

  log = Logging.logger[Pulp3RpmMirrorSlimmer]
  log.add_appenders(
    Logging.appenders.stdout(
      layout: Logging.layouts.pattern(color_scheme: 'bright')
    ),
    Logging.appenders.rolling_file(
      "#{File.basename(log_file,'.log')}.debug.log",
      level: :debug,
      layout: Logging.layouts.pattern(backtrace: true),
      truncate: true
    ),
    Logging.appenders.rolling_file(
      "#{File.basename(log_file,'.log')}.info.log",
      level: :info,
      layout: Logging.layouts.pattern(backtrace: true),
      truncate: true
    )
  )
  log.level = :verbose
  log
end

options = parse_options
puts options.to_yaml
p ARGV

mirror_slimmer = Pulp3RpmMirrorSlimmer.new(
  build_name: options[:pulp_label_session],
  pulp_user:     options[:pulp_user],
  pulp_password: options[:pulp_password],
  logger: get_logger(log_file: 'rpm_mirror_slimmer.log')
)

mirror_slimmer.do(
  action:               options[:action],
  repos_to_mirror_file: options[:repos_to_mirror_file],
)

puts "\nFINIS"
