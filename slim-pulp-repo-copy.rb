#!/opt/puppetlabs/bolt/bin/ruby
# TODO: use pulp labels to identify repo build session/purpose for cleanup/creation

require 'uri'
require 'yaml'
require 'fileutils'
require 'tempfile'

# Workaround to let bundler run bolt
BOLT_CMD=(<<~CLEAN_BOLT_ENV
env \
  -u GEM_HOME \
  -u GEM_PATH \
  -u DLN_LIBRARY_PATH \
  -u RUBYLIB \
  -u RUBYLIB_PREFIX \
  -u RUBYOPT \
  -u RUBYPATH \
  -u RUBYSHELL \
  -u LD_LIBRARY_PATH \
  -u LD_PRELOAD \
  BOLT_ORIG_GEM_PATH=$GEM_PATH \
  BOLT_ORIG_GEM_HOME=$GEM_HOME \
  BOLT_ORIG_RUBYLIB=$RUBYLIB \
  BOLT_ORIG_RUBYLIB_PREFIX=$RUBYLIB_PREFIX \
  BOLT_ORIG_RUBYOPT=$RUBYOPT \
  BOLT_ORIG_RUBYPATH=$RUBYPATH \
  BOLT_ORIG_RUBYSHELL=$RUBYSHELL \
  /opt/puppetlabs/bolt/bin/bolt
CLEAN_BOLT_ENV
).gsub(/\s+/, ' ').strip

PULP_HOST = "http://localhost:#{ENV['PULP_PORT'] || `#{BOLT_CMD} lookup --plan-hierarchy pulp3::server_port`.strip.to_i || 8080}"

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
class Pulp3RpmRepoSlimmer
  def initialize(
    build_name:,
    distro_base_path:,
    logger:,
    pulp_user: 'admin',
    pulp_password: 'admin',
    cache_dir: '.rpm-cache',
    upload_chunk_size: 6291456
  )
    @build_name = build_name
    @distro_base_path = distro_base_path
    @log = logger
    @pulp_labels = {
      'simpbuildsession' => "#{build_name}-#{Time.now.strftime("%F")}",
    }
    @cache_dir = cache_dir
    @upload_chunk_size = upload_chunk_size

    begin
      pulp_host_uri = URI(PULP_HOST)
    rescue
      $stderr.puts("PULP_HOST must be a valid URI: #{e}")
    end

    require 'pulpcore_client'
    require 'pulp_rpm_client'

    # For all options, see:
    #
    #    https://www.rubydoc.info/gems/pulpcore_client/PulpcoreClient/Configuration
    #
    PulpcoreClient.configure do |config|
      config.host = PULP_HOST
      config.scheme = pulp_host_uri.scheme
      config.username = pulp_user
      config.password = pulp_password
      config.debugging = ENV['DEBUG'].to_s.match?(/yes|true|1/i) # TODO parameter
      # config.logger =  # Defines the logger used for debugging.
    end


    # For all options, see:
    #
    #    https://www.rubydoc.info/gems/pulp_rpm_client/PulpRpmClient/Configuration
    #
    PulpRpmClient.configure do |config|
      config.host = PULP_HOST
      config.scheme = pulp_host_uri.scheme
      config.username = pulp_user
      config.password = pulp_password
      config.debugging = ENV['DEBUG'].to_s.match?(/yes|true|1/i) # TODO parameter
    end

    @ReposAPI                   = PulpRpmClient::RepositoriesRpmApi.new
    @RemotesAPI                 = PulpRpmClient::RemotesRpmApi.new
    @RepoVersionsAPI            = PulpRpmClient::RepositoriesRpmVersionsApi.new
    @PublicationsAPI            = PulpRpmClient::PublicationsRpmApi.new
    @DistributionsAPI           = PulpRpmClient::DistributionsRpmApi.new
    @ContentPackagesAPI         = PulpRpmClient::ContentPackagesApi.new
    @ContentPackagegroupsAPI    = PulpRpmClient::ContentPackagegroupsApi.new
    @ContentModulemdsAPI        = PulpRpmClient::ContentModulemdsApi.new
    @ContentModulemdDefaultsAPI = PulpRpmClient::ContentModulemdDefaultsApi.new
    @RpmCopyAPI                 = PulpRpmClient::RpmCopyApi.new

    @TasksAPI                   = PulpcoreClient::TasksApi.new
    @ArtifactsAPI               = PulpcoreClient::ArtifactsApi.new
    @UploadsAPI                 = PulpcoreClient::UploadsApi.new
  end

  def wait_for_task_to_complete(task, opts = {})
    opts = { sleep_time: 10 }.merge(opts)

    # Wait for sync task to complete
    until %w[completed failed].any? { |state| @TasksAPI.read(task).state == state }
      task_info = @TasksAPI.read(task)
      @log.verbose "#{Time.now} ...Waiting for task '#{task_info.name}' to complete (status: '#{task_info.state})'"
      @log.debug "( pulp_href: #{task_info.pulp_href} )"
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
    @log.info("Ensuring that RPM repo '#{name}' exists (idempotently)")
    repos_data = nil
    repos_list = @ReposAPI.list(name: name)
    if repos_list.count > 0
      @log.verbose "Repo '#{name}' already exists, moving on..."
      repos_data = repos_list.results[0]
    else
      rpm_rpm_repository = PulpRpmClient::RpmRpmRepository.new(
        name: name,
        pulp_labels: labels,
        retain_repo_versions: 1,     # Significant speedup
        retain_package_versions: 2,  # Note: can't combine with mirror_content_only sync policy
      )
      repos_data = @ReposAPI.create(rpm_rpm_repository, opts)
    end
    @log.success("Finished: Ensuring that RPM repo '#{name}' exists (idempotently)")
    @log.debug repos_data.to_hash.to_yaml
    repos_data
  end


  # Download a file directly from a URL
  def download_file(url, dest_dir)
    @log.info("== Ensuring file is cached: #{url} to #{dest_dir}")
    require 'down'
    filename = File.basename(url)
    downloaded_file = File.join(dest_dir,filename)
    remote_file = Down.open(url)
    unless File.exist?(downloaded_file) && File.size(downloaded_file) == remote_file.size
      @log.verbose("Downloading #{url} to #{downloaded_file}")
      Down.download(url, destination: downloaded_file)
    else
      @log.verbose("Skipping download, already in cache: #{downloaded_file}")
    end
    remote_file.close
    downloaded_file
  end

  def upload_artifact(file_path)
    file = File.open(file_path,'rb')
    sha256sum = Digest::SHA256.hexdigest(File.read(file_path))

    # Idempotency
    existing_list = @ArtifactsAPI.list({ sha256: sha256sum })
    if existing_list.count > 0
      artifact = existing_list.results.first
      @log.verbose("No need to upload '#{file_path}'; artifact already exists")
      @log.debug("Artifact for '#{file_path}': #{artifact.pulp_href} (sha256sum: #{sha256sum}")
      return artifact
    end

    # https://docs.pulpproject.org/pulpcore/workflows/upload-publish.html
    upload = PulpcoreClient::Upload.new(size: file.size)
    upload_response = @UploadsAPI.create(upload)

    start_offset = 0
    file.seek(start_offset,IO::SEEK_SET)

    while data_chunk = file.read(@upload_chunk_size) do
      Tempfile.create do |chunk_file|
        chunk_file.write(data_chunk)
        chunk_file.flush
        content_range = "bytes #{start_offset}-#{file.pos - 1}/#{file.size}"
        @log.debug("Uploading #{file_path} [#{content_range}/#{file.size}]")
        @UploadsAPI.update(
          content_range,
          upload_response.pulp_href,
          chunk_file
        )
      end
      start_offset = file.pos
    end

    # Finalize + create artifact from chunked upload
    async_response = @UploadsAPI.commit(
      upload_response.pulp_href,
      PulpcoreClient::UploadCommit.new({sha256: sha256sum})
    )
    artifact_href = wait_for_create_task_to_complete(async_response.task).first
    @ArtifactsAPI.read( artifact_href )
  end

  def upload_rpm_to_repo(file_path, repo)
    @log.info("== Uploading #{file_path} to #{repo.name}")
    basename = File.basename(file_path)

    artifact = upload_artifact(file_path)

    # Idempotency for content & repo
    existing_rpm_list = @ContentPackagesAPI.list({
      sha256: artifact.sha256,
      exclude_fields: 'files',
    })

    if existing_rpm_list.count > 0
      rpm_package = existing_rpm_list.results.first
      @log.verbose("No need to add RPM package '#{rpm_package.name}'; content unit already exists")
      @log.debug("RPM package content unit for '#{rpm_package.name}': #{rpm_package.pulp_href} (sha256: #{artifact.sha256}")

      orig_repo_version_href = @ReposAPI.read(repo.pulp_href).latest_version_href
      content_change = PulpRpmClient::RepositoryAddRemoveContent.new({
        add_content_units: [ rpm_package.pulp_href ],
        base_version: orig_repo_version_href,
      })

      async_response = @ReposAPI.modify(repo.pulp_href, content_change)
      rpm_rpm_repository_version_href = wait_for_create_task_to_complete(
        async_response.task,{sleep_time: 1}
      ).first || orig_repo_version_href

      if orig_repo_version_href != rpm_rpm_repository_version_href
        @log.info("Added RPM package '#{rpm_package.name}' to repo '#{repo.name}'")
        @log.verbose("   Old repo version: #{orig_repo_version_href}" )
        @log.verbose("   New repo version: #{rpm_rpm_repository_version_href}")
      else
        @log.verbose("RPM package '#{rpm_package.name}' already in repo '#{repo.name}'")
      end
      return rpm_rpm_repository_version_href
    end

    async_response = @ContentPackagesAPI.create(
      basename, {
        artifact: artifact.pulp_href,
        repository: repo.pulp_href,
      }
    )
    created_resources = wait_for_create_task_to_complete(
      async_response.task, { max_expected_resources: 2 }
    )
    rpm_rpm_repository_version_href = created_resources.select do |x|
      x =~ %r[pulp/api/v3/repositories/rpm/rpm/.*/versions/]
    end.first

    unless rpm_rpm_repository_version_href
      raise 'Somehow, the content packages task created resources, but not a new RPM repository version'
    end

    return rpm_rpm_repository_version_href
  end

  # create & sync RPM remote to mirror repo at remote_url
  #
  # returns rpm_rpm_repository_version_href for mirrored repo
  def create_rpm_repo_mirror(name:, remote_url:, repo:, pulp_remote_options: {}, pulp_labels: {}, rpms: [])
    @log.info "== Creating remote #{name} from #{remote_url}"

    @log.debug "-- repo: #{repo.pulp_href}"
    # If all RPMs are direct downloads, then don't sync the mirror
    mirror = rpms.empty? || !rpms.all?{ |rpm| rpm.key?('direct_url') }
    direct_downloads = rpms.select{|x| x.key?('direct_url') }

    rpm_rpm_repository_version_href = nil
    if mirror
      # Create RPM remote to mirror upstream repo
      begin
        paginated_rpm_rpm_remote_response_list = @RemotesAPI.list(name: name)
        remote_already_exists = paginated_rpm_rpm_remote_response_list.count == 1

        if remote_already_exists
          @log.verbose("No need to create RPM Remote '#{name}'; Remote already exists")
          remotes_data = paginated_rpm_rpm_remote_response_list.results.first
        else
          @log.verbose("Creating RPM Remote '#{name}'")

          # By default, only download RPMs on demand (wait until requested)
          remote_opts = {
            'name'                    => name,
            'url'                     => remote_url,
            'policy'                  => 'on_demand',
            # options intentionally not used:
            # mirror            => true,
            #'pulp_labels'    => pulp_labels,
            #'tls_validation' => false,
          }.merge( pulp_remote_options ).transform_keys(&:to_sym)

          rpm_rpm_remote = PulpRpmClient::RpmRpmRemote.new(remote_opts)
          remotes_data = @RemotesAPI.create(rpm_rpm_remote)
        end
        @log.debug( "#{name}: Remote #{remotes_data.pulp_href}" )

        # TODO split remote creation and repo sync into different functions

        rpm_repository_sync_url = PulpRpmClient::RpmRepositorySyncURL.new(
          remote: remotes_data.pulp_href,
          sync_policy: 'additive',
          skip_types: []            # This should be default, making _sure_
          # optimize: true
        )
        @log.verbose("Running sync for Remote '#{name}'")
        sync_async_info = @ReposAPI.sync(repo.pulp_href, rpm_repository_sync_url)

        rpm_rpm_repository_version_href = nil
        if remote_already_exists
          task_result = wait_for_task_to_complete(sync_async_info.task)
          if task_result.created_resources.empty? && task_result.progress_reports.first.code == 'sync.was_skipped'
            @log.verbose("Sync skipped for Remote '#{name}' (using href '#{repo.latest_version_href})'")
            rpm_rpm_repository_version_href = repo.latest_version_href
          end
        end

        unless rpm_rpm_repository_version_href
          # max_expected_resources went from 1 to 3 after pulp_rpm got automatic publishing (3.12+)
          #   2 when syncing a new remote (new repo version + new publication)
          #   3 when syncing an existing remote (new repo version + new pub + old repo version?)
          begin
            created_resources = wait_for_create_task_to_complete(sync_async_info.task, {max_expected_resources: 3})
            # NOTE Pulp now auto-creates 1-2 publications with the rpm version
            rpm_rpm_repository_version_href = created_resources.select{ |x| x =~ %r[^/pulp/api/v3/repositories/rpm/rpm/.*/versions/] }.first
          rescue RuntimeError => e
            @log.error "Exception when calling API: #{e}"
            require 'pry'; binding.pry
          end
        end

        unless rpm_rpm_repository_version_href
          @log.error "ERROR: RPM Repo sync did not create a new RPM Repo version!"
          require 'pry'; binding.pry
        end
      rescue PulpcoreClient::ApiError, PulpRpmClient::ApiError => e
        @log.error "Exception when calling API: #{e}"
        @log.warn "===> #{e}\n\n#{e.backtrace.join("\n").gsub(/^/, '    ')}\n\n==> INVESTIGATE WITH PRY"
        raise e
      end
    else
      @log.warn "All RPMs for repo '#{name}' are direct downloads; no mirror created"
    end

    unless direct_downloads.empty?
      # add_external_rpms_to_repo(name:, repo:, rpms:)
      # - [x] download RPM(s) to working dir
      # - [x] add RPM(s) to repo --> new repo version
      #   - [x] upload artifact to pulp - https://pulp-rpm.readthedocs.io/en/latest/workflows/upload.html
      #   - [x] create rpm package content from artifact
      #   - [x] add content to repository (supports multiple content units)

      repo_cache_dir = File.join(@cache_dir,repo.name)
      downloaded_rpms = direct_downloads.map do |rpm|
        FileUtils.mkdir_p(repo_cache_dir)
        downloaded_file = download_file(rpm['direct_url'], repo_cache_dir)
        rpm_rpm_repository_version_href = upload_rpm_to_repo(downloaded_file, repo)
      end
    end
    @log.debug( "-- create_rpm_repo_mirror: returning rpm_rpm_repository_version_href: '#{rpm_rpm_repository_version_href}'" )
    rpm_rpm_repository_version_href
  end

  def ensure_rpm_publication(rpm_rpm_repository_version_href, labels = {})
    @log.info( "== Ensuring RPM publication exists for RPM version  #{rpm_rpm_repository_version_href}" )
    pub_href = nil
    begin
      list = @PublicationsAPI.list(repository_version: rpm_rpm_repository_version_href)
      if list.count > 0
        @log.verbose "Publication for '#{rpm_rpm_repository_version_href}' already exists, moving on"
        return list.results.first
      end
      # Create Publication
      rpm_rpm_publication = PulpRpmClient::RpmRpmPublication.new(
        repository_version: rpm_rpm_repository_version_href,
        metadata_checksum_type: 'sha256'
      )
      pub_sync_info = @PublicationsAPI.create(rpm_rpm_publication)
      pub_created_resources = wait_for_create_task_to_complete(pub_sync_info.task, {sleep_time: 2})
      pub_href = pub_created_resources.first
    rescue PulpcoreClient::ApiError, PulpRpmClient::ApiError => e
      @log.error "Exception when calling API: #{e}"
      @log.warn "===> #{e}\n\n#{e.backtrace.join("\n").gsub(/^/, '    ')}\n\n==> INVESTIGATE WITH PRY"
      require 'pry'; binding.pry
    end
    @log.info( "== Ensuring RPM publication exists for RPM version  #{rpm_rpm_repository_version_href}" )
     @PublicationsAPI.read( pub_href )
  end

  def ensure_rpm_distro(unique_name:, pub_href:, name:,  labels: {})
    @log.info( "== Ensuring RPM distro '#{unique_name}' exists for publication '#{pub_href}' (idempotently)")
    result = nil
    begin
      base_path = "#{@distro_base_path.sub(%r[/$],'')}/#{name}"
      rpm_rpm_distribution = PulpRpmClient::RpmRpmDistribution.new({
        name: unique_name,
        base_path: base_path,
        publication: pub_href,
        pulp_labels: labels,
      })

      list = @DistributionsAPI.list(name: unique_name)
      if list.count > 0
        distro = list.results.first
        if distro.publication == pub_href
          @log.verbose "RPM distro '#{unique_name}' already exists with publication #{pub_href}, moving on"
          return distro
        end
        @log.info "== Updating distro '#{unique_name}' with publication #{pub_href}"
        dist_sync_info = @DistributionsAPI.update(distro.pulp_href, rpm_rpm_distribution)
        wait_for_task_to_complete(dist_sync_info.task)
        @log.success("Updated RPM distro '#{unique_name}'")
        return @DistributionsAPI.list(name: unique_name).results.first
      end

      # Create Distribution
      @log.info "== Creating RPM distro '#{unique_name}' with publication #{pub_href}"
      dist_sync_info = @DistributionsAPI.create(rpm_rpm_distribution)
      dist_created_resources = wait_for_create_task_to_complete(dist_sync_info.task)
      dist_href = dist_created_resources.first
      dist_href.inspect
      distribution_data = @DistributionsAPI.list({ base_path: base_path })
      @log.verbose("Distro HREF: #{dist_href}")
      @log.success("Created RPM distro '#{unique_name}' with publication #{pub_href}")
      return(distribution_data.results.first)
    rescue PulpcoreClient::ApiError, PulpRpmClient::ApiError => e
      @log.error "Exception when calling API: #{e}"
      @log.warn "===> #{e}\n\n#{e.backtrace.join("\n").gsub(/^/, '    ')}\n\n==> INVESTIGATE WITH PRY"
      require 'pry'; binding.pry
    end
    @log.recovery("Done ensuring RPM distro '#{unique_name}' (how did we get to this line?)")
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
        wait_for_task_to_complete(delete_async_info.task, {sleep_time: 2})
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

  def modmd_reqs_to_hashes( modmd_reqs )
    reqs = modmd_reqs.map do |x|
      y = x['stream'].split(':')
      {
        name: y[0],
        stream: y[1],
        version: y[2],
        context: y[3],
        arch: y[4],
      }
    end
  end


  def get_modulemd_defaults_hrefs(repo_version_href, modmd_reqs)
    unless modmd_reqs && modmd_reqs.size > 0
      @log.verbose("No modulemd_defaults given for repo #{repo_version_href}; skipping get_modulemd_defaults_hrefs")
      return []
    end
    reqs = modmd_reqs_to_hashes( modmd_reqs ).uniq
    limit = 100
    results = []

    api_results = []
    api_result_count = nil
    offset = 0
    next_url = nil

    until offset > 0 && next_url.nil? do
      @log.verbose( "  pagination: #{offset}#{api_result_count ? ", total considered: #{offset}/#{api_result_count}" : ''} ")

      paginated_response_list = @ContentModulemdDefaultsAPI.list({
        repository_version: repo_version_href,
        name__in: reqs.map{|x| x[:name] },
        stream__in: reqs.map{|x| x[:stream] },
      })
      selected_results = paginated_response_list.results || []
      api_results += selected_results
      offset += selected_results.size
      next_url = paginated_response_list._next
      api_result_count = paginated_response_list.count
      require 'pry'; binding.pry if paginated_response_list.results.size == 0
    end

    # Not all modules have defaults
    missing = reqs.select {|x| api_results.none?{|y| x[:name] == y._module && x[:stream] == y.stream }}.map{|x| x[:name] }.uniq
    unless missing.empty?
      repo = @ReposAPI.read(File.dirname(File.dirname(repo_version_href))+'/')
      msg = "\nNOTICE: Some modules have no modulemd_defaults in repo #{repo.name} (this is normal):\n  - #{missing.join("\n  - ")}\n\n"
      @log.verbose msg
      warn msg
    end

    api_results.map{|x| x.pulp_href }
  end

  def get_modulemd_hrefs(repo_version_href, modmd_reqs)
    unless modmd_reqs && modmd_reqs.size > 0
      @log.verbose("No modulemds given for repo #{repo_version_href}; skipping get_modulemd_hrefs")
      return []
    end
    reqs = modmd_reqs_to_hashes( modmd_reqs ).uniq

    limit = 100
    results = []

    api_results = []
    api_result_count = nil
    offset = 0
    next_url = nil

    until offset > 0 && next_url.nil? do
      @log.verbose( "  pagination: #{offset}#{api_result_count ? ", total considered: #{offset}/#{api_result_count}" : ''} ")


      paginated_response_list = @ContentModulemdsAPI.list({
        repository_version: repo_version_href,
        # In this case, the *__in: params take an actual array and *not( a
        # comma-delmited string:
        name__in: reqs.map{|x| x[:name] },
        stream__in: reqs.map{|x| x[:stream] },
        fields: 'name,stream,version,context,arch,pulp_href',
      })

      # GET rpm/modulmds/ does not accept query parameters to filter by module
      # version, context, or arch, so we do it with the results
      selected_results = paginated_response_list.results.select do |x|
        reqs.any? do |r|
          ns_ok = x.name == r[:name] && x.stream == r[:stream]
          # V:C:A are optional fields in the yaml file's modules
          # so only fail if they aren specified bu don't match
          v_ok = r[:version] ? x.version == r[:version]: true
          c_ok = r[:context] ? x.context == r[:context] : true
          a_ok = r[:arch] ? x.arch == r[:arch] : true
          ns_ok && v_ok && c_ok && a_ok
        end
      end || []
      api_results += selected_results
      offset += selected_results.size
      next_url = paginated_response_list._next
      api_result_count = paginated_response_list.count
      require 'pry'; binding.pry if paginated_response_list.results.size == 0
    end

    repo = @ReposAPI.read(File.dirname(File.dirname(repo_version_href))+'/')
    # The API query above only takes one call, but it can return false
    # positives (e.g., just name or just stream).  In addition, it can return
    # multiple items for an ns with multiple versions/contexts/arches
    # TODO: should we handle contexts and arches?
    req_api_results = reqs.map do |r|
      ns="#{r[:name]}:#{r[:stream]}"
      res = api_results.select{|x| x.name == r[:name] && x.stream == r[:stream]}
      if res.size > 1
        @log.warn "WARNING: multiple modulemds matched for req '#{r}' in repo #{repo.name}; picking the latest version"
        res = [res.sort_by{|x| x.version }.last]
      end
      [ns, res]
    end.to_h

    missing = req_api_results.select{|k,v| v.empty?}.map{|k,v| k }
    unless missing.empty?
      fail_msg = "\nFATAL: Repo #{repo.name} was missing #{missing.size} requested module streams:\n  - #{missing.join("\n  - ")}\n\n"
      @log.fatal fail_msg
      fail fail_msg
    end

    req_api_results.values.flatten.map{ |x| x.pulp_href }
  end


  def get_packagegroup_hrefs(repo_version_href, pkggrp_reqs)
    unless pkggrp_reqs && pkggrp_reqs.size > 0
      @log.verbose("No packagegroups given for repo #{repo_version_href}; skipping get_packagegroup_hrefs")
      return []
    end
    reqs = pkggrp_reqs.map{|x| x['id'] }
    limit = 100
    results = []
    repo = @ReposAPI.read(File.dirname(File.dirname(repo_version_href))+'/')

    api_results = []
    api_result_count = nil
    offset = 0
    next_url = nil

    until offset > 0 && next_url.nil? do
      @log.verbose( "  pagination: #{offset}#{api_result_count ? ", total considered: #{offset}/#{api_result_count}" : ''} ")

      paginated_response_list = @ContentPackagegroupsAPI.list({
        repository_version: repo_version_href,
        fields: 'id,name,packages,description,digest,pulp_href',
      })

      selected_results = paginated_response_list.results.select{|x| reqs.include?(x.id) } || []
      api_results += selected_results
      offset += selected_results.size
      next_url = paginated_response_list._next
      api_result_count = paginated_response_list.count
      require 'pry'; binding.pry if paginated_response_list.results.size == 0
    end

    # Check that we found all reqs
    missing = reqs - api_results.map{|x| x.id }
    unless missing.empty?
      @log.fatal "\nFATAL: Repo #{repo.name} was missing #{missing.size} requested Package groups:\n  - #{missing.join("\n  - ")}\n\n"
    fail "\nFATAL: Repo #{repo.name} was missing #{missing.size} requested Package groups:\n  - #{missing.join("\n  - ")}\n\n"
    end

    api_results.map { |x| x.pulp_href }
  end

  # We need a pulp href for each RPM, but Pulp's API returns *every* version
  # for a name.
  #
  #   - We only want a single RPM for each name:
  #   - It should be the best version (NEVRA) available
  #   - There may be constraints for specific packages (particular/max version)
  #     - (in which case: pick the best of what's left)
  #   - Assumptions:
  #     - If `<name>.x86_64` exists, discard `<name>.i686` as unnecessary
  #     - Not sure about <name>.x86_64 & <name>.noarch (does this happen?)
  #
  def get_rpm_hrefs(repo_version_href, rpm_reqs)
    unless rpm_reqs && rpm_reqs.size > 0
      @log.verbose("No rpms given for repo #{repo_version_href}; skipping get_rpm_hrefs")
      return []
    end
    limit = 100
    rpm_batch_size = limit
    api_results = []
    results = []
    repo = @ReposAPI.read(File.dirname(File.dirname(repo_version_href))+'/')

    api_result_count = nil
    queried_rpms_count = 0

    # The API can only look for so many RPMs at a time, so query in batches
    rpm_reqs.each_slice(rpm_batch_size).to_a.each do |slice_of_rpms|
      @log.verbose("Querying RPMs by name, batch: #{queried_rpms_count+1}-#{queried_rpms_count+slice_of_rpms.size}/#{rpm_reqs.size}")
      rpm_names = slice_of_rpms.map{|r| r['name']}
      queried_rpms_count += rpm_names.size
      offset = 0
      next_url = nil

      until offset > 0 && next_url.nil? do
        @log.verbose( "  pagination: #{offset}#{api_result_count ? ", total considered: #{offset}/#{api_result_count}" : ''} ")

        paginated_package_response_list = @ContentPackagesAPI.list({
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
        require 'pry'; binding.pry if paginated_package_response_list.results.size == 0
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
          found_match = false

          dep_constraints = rpm_req['version'].dup
          dep_constraints = [ dep_constraints ] if dep_constraints.is_a?(String)
          dep_constraints.map! { |x| x.match(/<|>|=| /) ? x : "= #{x}" }

          found_match = Gem::Dependency.new('', rpm_req['version']).match?('', Gem::Version.new(r.version))

          found_match = (rpm_req['epoch'] == r.epoch) if found_match && rpm_req['epoch']
          found_match = (rpm_req['release'] == r.release) if found_match && rpm_req['release']
          found_match = (rpm_req['arch'] == r.arch) if found_match && rpm_req['arch']


          found_match
        end

        # fail/@log.warn when no RPMs meet constraints
        raise "ERROR: No '#{rpm_name}' RPMs met the version constraint: '#{rpm_req['version']}' (#{size} considered)" if n_rpms.empty?
      end

      # find the best RPM for each arch
      n_rpms.map{|r| r.arch }.uniq.each do |arch|
        na_rpms = n_rpms.select{|r| r.arch == arch }

        # pick the best RPM version (NEVR) for each arc
        nevr_rpms = na_rpms.sort do |a,b|
          [a.epoch, a.version, a.release] <=> [b.epoch, b.version, b.release]
        end

        n_results << nevr_rpms.last
      end

      # discard `<name>.i686` unless there is no `<name>.86_64`
      if n_results.any?{|x| x.arch == 'i686' } && n_results.any?{|x| x.arch == 'x86_64' }
        @log.warn "WARNING: Ignoring #{rpm_name}.i686 because #{rpm_name}.x86_64 exists"
        n_results.reject!{|x| x.arch == 'i686' }
      end

      # This would still be a weird case, so investigate it until we know what to expect
      if n_results.size > 1
        @log.warn "WARNING: RPMs for muliple arches found for '#{rpm_name}': #{n_results.map{|r| r.arch }.uniq.join(', ')}"
        sleep 1
        @log.todo "We haven't seen this before.  Investigate!"
        require 'pry'; binding.pry
      end

      results = n_results + results
    end

    # Check that we found all rpm_reqs
    missing_names = rpm_reqs.map{|r| r['name']}.uniq - results.map(&:name).uniq
    unless missing_names.empty?
      @log.fatal "\nFATAL: Repo #{repo.name} was missing #{missing_names.size} requested RPMs:\n  - #{missing_names.join("\n  - ")}\n\n"
    fail "\nFATAL: Repo #{repo.name} was missing #{missing_names.size} requested RPMs:\n  - #{missing_names.join("\n  - ")}\n\n"
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
        'content' => data[:required_rpm_hrefs] + data[:required_packagegroup_hrefs] + data[:required_modulemd_hrefs] + data[:required_modulemd_d_hrefs],
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
      task_result = wait_for_task_to_complete(async_response.task)

      raise PulpcoreClient::ApiError, "Pulp3 ERROR: Task #{async_response.task} failed:\n\n#{task_result.error['description']}" if task_result.state == 'failed'

      @log.info "== Sucessfully copied RPMs+dependencies into dest repositories"
      async_response.task
    rescue PulpRpmClient::ApiError, PulpcoreClient::ApiError => e
      @log.error "Exception when calling API: #{e}"
      require 'pry'; binding.pry
      raise e
    end
  end

  def delete_rpm_repo_mirrors(repos_to_mirror)
    repos_to_mirror.each do |name, data|
      delete_rpm_repo_mirror(name)
      delete_rpm_repo_mirror(name.sub(/^pulp\b/, @build_name))
    end
  end

  def do_create_new_repo_mirrors(repos_to_mirror)
    # TODO: Safety check to only destroy repos if pulp labels are identical?
    pulp_labels = @pulp_labels.merge({ 'reporole' => 'remote_mirror' })

    FileUtils.mkdir_p @cache_dir

    repos_to_mirror.each do |name, data|
      repo = ensure_rpm_repo(name, pulp_labels)
      url = data['url']

      rpm_rpm_repository_version_href = create_rpm_repo_mirror(
        name: name,
        remote_url: url,
        repo: repo,
        pulp_remote_options: data['pulp_remote_options'] || {},
        pulp_labels: pulp_labels,
        rpms: data['rpms'] || [] # for possible direct downloads
      )
require 'pry'; binding.pry unless rpm_rpm_repository_version_href
      publication = ensure_rpm_publication(rpm_rpm_repository_version_href, pulp_labels)
      distro = ensure_rpm_distro(
        unique_name: name,
        pub_href: publication.pulp_href,
        name: data['name'],
        labels: pulp_labels
      )
    end
  end


  # Ensures slim repos exist for repos_to_mirror
  # @return [Hash] slim_repos data structure
  def slim_repos_data_for(repos_to_mirror)
    pulp_labels = @pulp_labels.merge({ 'reporole' => 'slim_repo' })
    slim_repos = {}

    repos_to_mirror.each do |name, data|
      @log.info("== Ensuring slim repo mirror of '#{name}'")
      source_repo_version_href = get_repo_version_from_distro(name).pulp_href
      required_rpm_hrefs = get_rpm_hrefs(source_repo_version_href, data['rpms']||[] )
      required_pkggrp_hrefs = get_packagegroup_hrefs(source_repo_version_href, data['packagegroups']||[])
      required_modulemd_hrefs = get_modulemd_hrefs(source_repo_version_href, data['modules']||[])
      required_modulemd_d_hrefs = get_modulemd_defaults_hrefs(source_repo_version_href, data['modules']||[])

      slim_repo_name = name + '.slim'
      repo = ensure_rpm_repo(slim_repo_name, pulp_labels)

      slim_repos[slim_repo_name] ||= {}
      slim_repos[slim_repo_name][:pulp_href] = repo.pulp_href
      slim_repos[slim_repo_name][:source_repo_unique_name] = name
      slim_repos[slim_repo_name][:source_repo_name] = data['name']
      slim_repos[slim_repo_name][:name] = "slim-#{data['name']}"
      slim_repos[slim_repo_name][:source_repo_version_href] = source_repo_version_href
      slim_repos[slim_repo_name][:required_rpm_hrefs] = required_rpm_hrefs
      slim_repos[slim_repo_name][:required_packagegroup_hrefs] = required_pkggrp_hrefs
      slim_repos[slim_repo_name][:required_modulemd_hrefs] = required_modulemd_hrefs
      slim_repos[slim_repo_name][:required_modulemd_d_hrefs] = required_modulemd_d_hrefs
      @log.success("Slim repo mirror '#{slim_repo_name}' exists to copy from '#{name}'")
    end
    slim_repos
  end

  def write_slim_repos_debug_data(slim_repos, output_repo_debug_config)
    @log.info "\nWriting slim_repos debug data to: '#{output_repo_debug_config}"
    File.open(output_repo_debug_config, 'w') { |f| f.puts slim_repos.to_yaml }
  end

  def write_slim_repos_config_file(slim_repos, output_repo_file)
    yum_repo_file_content = slim_repos.map do |k,v|
      result = <<~REPO_ENTRY
        [pulp-#{v[:source_repo_name]}]
        name=#{v[:source_repo_name]} (Slim)
        enabled=1
        baseurl=#{v[:distro_url]}
        gpgcheck=0
        repo_gpgcheck=0
      REPO_ENTRY
       "#{result}\n"
    end

    @log.info "\nWriting slim_repos repo config to: '#{output_repo_file}"
    File.open(output_repo_file, 'w') { |f| f.puts yum_repo_file_content }
    yum_repo_file_content
  end

  def write_slim_repos_dnf_mirror_cmd(slim_repos, output_repo_script)
    dnf_mirror_cmd = <<~REPOSYNC_CMD
      #!/bin/sh
      # On EL7, ensure:
      #    yum install -y dnf dnf-plugins-core
      #
      set -eu

      # Useful EL8-only options: --remote-time --norepopath
      PATH_TO_LOCAL_MIRROR="$PWD/_download_path/#{@build_name}"
      mkdir -p "$PATH_TO_LOCAL_MIRROR"
      dnf reposync \\
        --download-metadata --downloadcomps \\
        --download-path "$PATH_TO_LOCAL_MIRROR" \\
        --setopt=reposdir=/dev/null \\
      REPOSYNC_CMD

    dnf_mirror_cmd += slim_repos.map { |k,v| "  --repofrompath #{v[:source_repo_name]},#{v[:distro_url]}" }.join(" \\\n")
    dnf_mirror_cmd += " \\\n" + slim_repos.map { |k,v| "  --repoid #{v[:source_repo_name]}" }.join(" \\\n")
    dnf_mirror_cmd += "\n\n" + 'printf "\nMirrored all repos into: %s\n\n" "$PATH_TO_LOCAL_MIRROR"' + "\n"
    File.open(output_repo_script, 'w') { |f| f.puts dnf_mirror_cmd }

    dnf_mirror_cmd += <<~REPO_GENERATOR

      # Create .repo file
      YUMREPO_FILE="$PATH_TO_LOCAL_MIRROR/simp-and-all-deps.repo"

      echo '# Yum repos for SIMP + all dependencies (slimmed)' > "$YUMREPO_FILE"
      echo '# Generated by #{output_repo_script}' >> "$YUMREPO_FILE"
      for repo in #{slim_repos.map{|k,v| v[:source_repo_name]}.join(' ')}; do

      echo "Adding '$repo' to .repo file..."
      cat << REPO >> "$YUMREPO_FILE"

      [${repo}]
      name=${repo}
      enabled=1
      baseurl=${REPOS_BASEURL:-$PATH_TO_LOCAL_MIRROR}/${repo}
      gpgcheck=${REPOS_GPGCHECK:-0}
      repo_gpgcheck=${REPOS_REPOGPGPCHECK:-0}
      REPO

      done

    REPO_GENERATOR

    dnf_mirror_cmd += "\n\n" + 'printf "\nWrote .repo file: %s\n\n" "$YUMREPO_FILE"' + "\n"

    @log.info "\nWriting slim_repos download script to: '#{output_repo_script}"
    File.open(output_repo_script, 'w') { |f| f.puts dnf_mirror_cmd }
    dnf_mirror_cmd
  end

  def write_slim_repos_dnf_repoclosure_cmd(slim_repos, output_repo_script)
    dnf_repoclosure_cmd = <<~CMD_START
      #!/bin/sh
      set -eu
      dnf repoclosure \\
      CMD_START

    dnf_repoclosure_cmd += slim_repos.map { |k,v|

      "  --repofrompath slim-#{v[:source_repo_name]},#{v[:distro_url]}"
    }.join(" \\\n")
    dnf_repoclosure_cmd += " \\\n" + slim_repos.map { |k,v| "  --repoid slim-#{v[:source_repo_name]}" }.join(" \\\n")


    @log.info "\nWriting slim_repos repoclosure script to: '#{output_repo_script}"
    File.open(output_repo_script, 'w') { |f| f.puts dnf_repoclosure_cmd }
    dnf_repoclosure_cmd
  end

  def do_copy_rpms_into_slim_repos(repos_to_mirror)
    pulp_labels = @pulp_labels.merge({ 'reporole' => 'slim_repo' })
    slim_repos = slim_repos_data_for(repos_to_mirror)

    # Slim RPM copy from all repos_to_mirror to all slim_repos
    advanced_rpm_copy(slim_repos)

    slim_repos.each do |name, data|
      rpm_rpm_repository_version_href = @ReposAPI.read(data[:pulp_href]).latest_version_href
      publication = ensure_rpm_publication(rpm_rpm_repository_version_href, pulp_labels)

      distro = ensure_rpm_distro(
        unique_name: name,
        pub_href: publication.pulp_href,
        name: data[:name]
      )
      slim_repos[name][:distro_href] = distro.pulp_href
      slim_repos[name][:distro_url] = distro.base_url
    end

    # Write results to files
    output_dir = 'output'
    FileUtils.mkdir_p(output_dir)

    output_file = File.join(output_dir, "_slim_repos.#{@build_name}.yaml")
    output_repo_file = File.join(output_dir, File.basename( output_file, '.yaml' ) + '.repo')
    output_repo_script = File.join(output_dir, File.basename( output_file, '.yaml' ) + '.reposync.sh')
    output_repoclosure_script = File.join(output_dir, File.basename( output_file, '.yaml' ) + '.repoclosure.sh')
    output_repo_debug_config = File.join(output_dir, File.basename( output_file, '.yaml' ) + '.api_items.yaml')
    output_versions_file = File.join(output_dir, File.basename( output_file, '.yaml' ) + '.versions.yaml')

    write_slim_repos_debug_data(slim_repos, output_repo_debug_config)
    yum_repo_file_content = write_slim_repos_config_file(slim_repos, output_repo_file)
    write_slim_repos_dnf_mirror_cmd(slim_repos, output_repo_script)
    write_slim_repos_dnf_repoclosure_cmd(slim_repos, output_repoclosure_script)
    FileUtils.chmod('ug+x', output_repo_script)
    FileUtils.chmod('ug+x', output_repoclosure_script)

    # Log/print slim repos
    @log.info "\nSlim repos:\n" + \
      slim_repos.map{ |k,v| "    #{v[:distro_url]}" }.join("\n") + "\n"

    @log.info "\nYum repo file content:\n#{yum_repo_file_content.join("\n")}"

    slim_repo_mirror_data = {}

    # Write versions file
    @log.verbose( "Fetching slim_repo package versions data for each repo" )
    slim_repos.each do |repo_name, data|
      rpm_rpm_repository_version =  get_repo_version_from_distro(repo_name)

      api_results = []
      api_result_count = nil
      limit = 100
      offset = 0
      next_url = nil
      @log.verbose( "Getting versions info for repo #{data[:source_repo_unique_name]}:")

      first=true
      until offset > 0 && next_url.nil? do
        ###@log.debug( "  pagination: #{offset}#{api_result_count ? ", total considered: #{offset}/#{api_result_count}" : ''} ")
        @log.verbose( "  pagination: #{offset}#{api_result_count ? ", total considered: #{offset}/#{api_result_count}" : ''} ")

        paginated_package_response_list = @ContentPackagesAPI.list({
          repository_version: rpm_rpm_repository_version.pulp_href,
          fields: 'epoch,name,version,release,arch,pulp_href,location_href,rpm_license,rpm_packager,rpm_vendor,summary,sha256,url,is_modular',
          limit: limit,
          offset: offset,
          order: 'version',
        })
        api_results += paginated_package_response_list.results
        offset += paginated_package_response_list.results.size
        next_url = paginated_package_response_list._next
        api_result_count = paginated_package_response_list.count

        break if offset == 0 && next_url.nil? && first
        first=false
      end

      repo_to_mirror = repos_to_mirror[data[:source_repo_unique_name]]
      slim_repo_mirror_data[data[:source_repo_name]] = repo_to_mirror.reject{|k,v| k=='rpms' || k=='name'}
      slim_repo_mirror_data[data[:source_repo_name]]['rpms'] = api_results.map do |rpm|
        {
          'name' => rpm.name,
          'version' => "= #{rpm.version}",
        }
      end
      slim_repo_mirror_data[data[:source_repo_name]]['sbom'] = api_results.map do |rpm|
        {
          'package' => rpm.location_href,
          'rpm_license' => rpm.rpm_license,
          'rpm_packager' => rpm.rpm_packager,
        }
      end
    end
    @log.info "\nWriting slim_repos versions data to: '#{output_versions_file}"
    File.open(output_versions_file, 'w') { |f| f.puts slim_repo_mirror_data.to_yaml }
  end

  def do(action:, repos_to_mirror_file:)
    repos_to_mirror = YAML.load_file(repos_to_mirror_file)

    labeled_repos_to_mirror = repos_to_mirror.map do |name, data|
      labeled_name = name.sub( /^/, "#{@build_name}.")
      labeled_data = data.dup
      labeled_data['name'] = name
      [ labeled_name, labeled_data ]
    end.to_h

    case action
    when :create_new
      delete_rpm_repo_mirrors(labeled_repos_to_mirror)
      do_create_new_repo_mirrors(labeled_repos_to_mirror)
      do_copy_rpms_into_slim_repos(labeled_repos_to_mirror)
    when :create_new_only
      do_create_new_repo_mirrors(labeled_repos_to_mirror)
      do_copy_rpms_into_slim_repos(labeled_repos_to_mirror)
    when :use_existing
      do_copy_rpms_into_slim_repos(labeled_repos_to_mirror)
    when :delete
      delete_rpm_repo_mirrors(labeled_repos_to_mirror)
    end
  end
end

OptsFilepath = String
OptsDirectoryPath = String
OptsYAMLFilepath = Hash
def parse_options
  require 'optparse'

  options = {
    action: :create_new_only,
    repos_to_mirror_file: nil,
    pulp_session_label: nil,
    pulp_distro_base_path: nil,
    pulp_user: 'admin',
    pulp_password: 'admin',
    cache_dir: '.rpm-cache'
  }

  opts_parser = OptionParser.new do |opts|
    opts.banner = "Usage:\n\n    #{opts.program_name} [options]"
    opts.banner += "\n\n"
    opts.banner += 'Options:'
    opts.banner += "\n\n"

    opts.accept(OptsYAMLFilepath) do |path|
      File.exist?(path) || fail("Could not find specified file: '#{path}'")
      File.file?(path) || fail("Argument is not a file: '#{path}'")
      YAML.parse_file(path) # raises exception if not valid YAML
      path
    end

    opts.accept(OptsDirectoryPath) do |path|
      # Is there anything to validate if we mkdir_p the directory before using it?
      path
    end

    opts.on(
      '-f', '--repos-rpms-file YAML_FILE', OptsYAMLFilepath,
      'YAML File with Repos/RPMs to include'
    ) do |f|
      options[:repos_to_mirror_file] = f
    end

    opts.on('-n', '--create-new', 'Delete existing + create new repo mirrors + Slim rpm copy') do
      options[:action] = :create_new
    end

    opts.on('-N', '--create-new-only', '(No delete) Create new repo mirrors + Slim rpm copy') do
      options[:action] = :create_new_only
    end

    opts.on('-e', '--use-existing', 'Slim rpm copy from existing repo mirrors') do
      options[:action] = :use_existing
    end

    opts.on('-d', '--delete-existing', 'Delete existing mirrors & repos') do
      options[:action] = :delete
    end

    opts.on(
      '-l', '--session-label LABEL',
      "Namespace-ish prefix for internal pulp entities",
      '(Default: based on the path of `-f YAML_FILE`)'
    ) do |text|
      options[:pulp_session_label] = text
    end

    opts.on(
      '-b', '--base-path PATH_PREFIX',
      'Base directories under which to host distros',
      '(Default: based on the path of `-f YAML_FILE`)'
    ) do |text|
      options[:pulp_distro_base_path] = text
    end

    opts.on('-c', '--cache-dir DIR', OptsDirectoryPath,
            "Path to directory for caching downloaded files" ) do |v|
      options[:cache_dir] = v
    end

### FIXME unimplemented
###
###    opts.on( '-R', '--local-rpms REPO_NAME,DIR',
###       'Upload RPMs from DIR to repo REPO_NAME',
###       '   Append `:!` to ignore url data from REPO_NAME',
###       '   NOTE: If REPO_NAME matches a repo from the ',
###       '   Repos/RPM data (-f), DIR will be used as the RPM source',
###       "   instead of the repo's url",
###    ) do |v|
###require 'pry'; binding.pry
###    end

    opts.on('-v', '--[no-]verbose', 'Run verbosely') do |v|
      options[:verbose] = v
    end

    opts.on_tail ''
  end

  begin
    opts_parser.parse!

    unless options[:repos_to_mirror_file]
      raise OptionParser::InvalidOption, 'missing `--repos-rpms-file YAML_FILE` !'
    end
  rescue OptionParser::InvalidOption => e
    warn '', "ERROR:\n\n    #{e.message}", ''
    puts opts_parser.help
    exit 1
  end

  options
end

def get_logger(log_dir: 'logs', log_file: 'rpm_mirror_slimmer.log', log_level: :debug)
  require 'logging'
  Logging.init :debug, :verbose, :info, :happy, :todo, :warn, :success, :recovery, :error, :fatal

  # here we setup a color scheme called 'bright'
  Logging.color_scheme(
    'bright',
    lines: {
      debug: :blue,
      verbose: :blue,
      info: :cyan,
      happy: :magenta,
      todo: %i[black on_yellow],
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

  FileUtils.mkdir_p(log_dir)

  log = Logging.logger[Pulp3RpmRepoSlimmer]
  log.add_appenders(
    Logging.appenders.stdout(
      layout: Logging.layouts.pattern(color_scheme: 'bright'),
      level: log_level
    ),
    Logging.appenders.rolling_file(
      "#{File.join(log_dir, File.basename(log_file,'.log'))}.debug.log",
      level: :debug,
      layout: Logging.layouts.pattern(backtrace: true),
      truncate: true
    ),
    Logging.appenders.rolling_file(
      "#{File.join(log_dir, File.basename(log_file,'.log'))}.info.log",
      level: :info,
      layout: Logging.layouts.pattern(backtrace: true),
      truncate: true
    )
  )

  log
end

options = parse_options

# Default label to filesystem and URL-safe version of repos_to_mirror_file path
unless options[:pulp_session_label]
  str = options[:repos_to_mirror_file].downcase.gsub(/[^a-z0-9\-]+/i, '-').sub(/[\.-](yaml|yml)$/i,'').gsub(/^-*/,'')
  options[:pulp_session_label] = File.basename( str )
end

# Default label to filesystem and URL-safe version of repos_to_mirror_file path
unless options[:pulp_distro_base_path]
  str = options[:repos_to_mirror_file].gsub(/[^a-z0-9\-\/]+/i, '-').gsub(%r[/?\.\.?/],'/').sub(/[\.-](yaml|yml)$/i,'').sub(/^build\//i,'')
  base = File.basename(str)
  dirs = File.dirname(str).sub(%r{/?$},'')
  options[:pulp_distro_base_path] = "#{base}/#{dirs}".gsub(%r[/[/.]+],'/').gsub(%r[/$],'')
end
puts options.to_yaml
p ARGV

mirror_slimmer = Pulp3RpmRepoSlimmer.new(
  build_name:       options[:pulp_session_label],
  distro_base_path: options[:pulp_distro_base_path],
  pulp_user:        options[:pulp_user],
  pulp_password:    options[:pulp_password],
  cache_dir:        options[:cache_dir],
  logger:           get_logger(log_file: 'rpm_mirror_slimmer.log')
)

mirror_slimmer.do(
  action:               options[:action],
  repos_to_mirror_file: options[:repos_to_mirror_file],
)

puts "\nFINIS"
