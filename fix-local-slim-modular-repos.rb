#!/opt/puppetlabs/bolt/bin/ruby
#
# Fixes the modulemd data in repos' modules.yaml files, so each stream only
# advertises the RPMs that are actually present in the primary.xml.gz
#
# Processes multple repo directories
#
# Usage:
#
#   ./slim_modular_repodata_fix.rb [ROOT_DIR_OF_REPOS]
#
# [ROOT_DIR_OF_REPOS] defaults to:
#
#    _download_path/build-6-6-0-centos-8-x86-64-repo-packages/
#
require 'yaml'
require 'fileutils'
require 'tempfile'
require 'nokogiri'
require 'terminal-table'

def get_logger(log_dir: 'logs', log_file: 'rpm.slim_modulemd_repodata_fix.log', log_level: :debug)
  require 'logging'
  Logging.init :debug2, :debug, :verbose, :info, :happy, :todo, :warn, :success, :recovery, :error, :fatal

  # here we setup a color scheme called 'bright'
  Logging.color_scheme(
    'bright',
    lines: { debug2: %i[dark blue], debug: %i[blue], verbose: %i[dark white], info: :white, happy: :magenta, todo: %i[black on_yellow], warn: :yellow, success: :green, recovery: %i[black on_green], error: :red, fatal: %i[white on_red] },
    date: :gray,
    logger: :cyan,
    message: :magenta
  )

  FileUtils.mkdir_p(log_dir)

  log = Logging.logger[SlimModuleMdFixer]
  log.add_appenders(
    Logging.appenders.stdout(
      layout: Logging.layouts.pattern(color_scheme: 'bright'),
      level: log_level
    ),
    Logging.appenders.rolling_file(
      "#{File.join(log_dir, File.basename(log_file,'.log'))}.debug2.log",
      level: :debug2,
      layout: Logging.layouts.pattern(backtrace: true),
      truncate: true
    )
  )
  log
end

class SlimModuleMdFixer
  def initialize(repo_dir:, logger:)
    @repo_dir = repo_dir
    @log = logger
    @repodata_dir = File.join(@repo_dir,'repodata')
    File.directory?(@repodata_dir) || fail("No repodata/ dir at '#{@repodata_dir}'")
    @repomd_xml = File.join(@repodata_dir,'repomd.xml')
    File.file?(@repomd_xml) || fail("No repomd.xml at '#{@repomd_xml}'")
    @short_repodir = File.basename(File.dirname(@repodata_dir))
  end


  require 'zlib'
  def gunzip(data)
    window_size = Zlib::MAX_WBITS + 16 # decode only gzip
    Zlib::Inflate.new(window_size).inflate(data)
  end


  def load_repomd_data_file(path)
    _path = path.dup
    _data = File.read(path)
    if File.basename(_path).split('.').last == 'gz'
      _path.gsub!(/\.gz$/,'')
      _data = gunzip(_data)
    end

    if File.basename(_path).split('.').last == 'xml'
      return( Nokogiri::XML.parse(_data))
    end

    if File.basename(_path).split('.').last == 'yaml'
      return YAML.load_stream(_data)
    end

    raise("Don't know how to read type of file at '#{path}'")
  end

  def get_repomd_xml_data_path(doc, type)
    doc = doc.dup
    doc.remove_namespaces! # bad form, but there's only one and I'm in a hurry
    _path = doc.xpath(%Q[//data[@type="#{type}"]/location/@href]).text

    fail("No '#{type}' data in #{@repomd_xml}") if _path.empty?

    path = File.join(@repo_dir,_path)
    File.file?(path) || fail("No #{type} file at '#{modules_yaml}'")
    path
  end

  def rebuild_modular_repo( modules_stream_path, fixed_mod_stream)
    backup_modules_stream_path = File.join(
      File.dirname(modules_stream_path),
     "previous-#{Time.now.strftime("%F")}-modules.yaml"
    )
    fixed_mod_stream_yaml = YAML.dump_stream(*fixed_mod_stream)

    FileUtils.cp modules_stream_path, backup_modules_stream_path, verbose: true

    Dir.mktmpdir do |tmpdir|
      full_path = File.join(tmpdir,'modules.yaml')
      File.write(full_path,fixed_mod_stream_yaml)
      cmd = %Q[modifyrepo_c --mdtype=modules --no-compress "#{full_path}" "#{@repodata_dir}"]
      @log.info "Running:\n\n\t#{cmd}\n"
      @log.debug messages = %x[#{cmd}]
      unless $?.success?
        raise "modifyrepo_c failed to rebuild repodata! (exit status #{$?.exitstatus})"
      end
    end
  end

  def slim_modulemd
    doc = Nokogiri::XML.parse( File.read(@repomd_xml) )

    modules_stream_path = get_repomd_xml_data_path(doc, 'modules')

    modules_stream = load_repomd_data_file(modules_stream_path)
    filelists_doc = load_repomd_data_file(get_repomd_xml_data_path(doc, 'filelists'))
    primary_doc = load_repomd_data_file(get_repomd_xml_data_path(doc, 'primary'))

    original_rpms = {}
    keep_rpms = {}

    fixed_mod_stream = modules_stream.map do |mod_stream|
      module_ns =  "#{mod_stream['data']['name']}:#{mod_stream['data']['stream']}"
      rpms = mod_stream['data']['artifacts']['rpms']
      present_rpms = rpms.reject do |rpm|
        next(true) if rpm =~ /\.src\Z/
        nevra = rpm.match(/\A(?<name>.+?)-(?<epoch>\d+):(?<ver>.+?)-(?<rel>\d+.*)\.(?<arch>[^.]+)\Z/)
        fail("Could not parse NEVRA from rpm name: #{rpm}") unless nevra

        elem_conditions = nevra.named_captures.select{|k,v| ['name','arch'].include?(k) }.map {|k,v| "xmlns:#{k}='#{v}'" }.join(' and ')
        attr_conditions = nevra.named_captures.reject{|k,v| ['name','arch'].include?(k) }.map {|k,v| "xmlns:version/@#{k}='#{v}'" }.join(' and ')
        e = primary_doc.xpath("//xmlns:package[#{elem_conditions} and #{attr_conditions}]", primary_doc.namespaces)
        e.empty?
      end
      keep_rpms[module_ns] = present_rpms
      original_rpms[module_ns] = rpms
      mod_stream['data']['artifacts']['rpms'] = present_rpms
      mod_stream
    end

    fixed_mod_stream.reject! do |mod_stream|
      mod_stream['data']['artifacts']['rpms'].empty?
    end

    if keep_rpms != original_rpms
      @log.info("FIXES NEEDED in #{@short_repodir}")

      rm_rpms_count = 0
      keep_rpms_count = 0
      rm_rpms = original_rpms.map do |k,v|
        rm_v = v - keep_rpms[k]
        rm_rpms_count += rm_v.size
        [k, rm_v]
      end.to_h

      modules_rm_summary = Terminal::Table.new(
        :title => "#{@short_repodir}: REMOVING (missing)",
        :headings => ['Module Stream','RPMs'],
        :rows => rm_rpms.map do |k,v|
          [k,v.size]
      end)
      modules_keep_summary = Terminal::Table.new(
        :title => "#{@short_repodir}: KEEPING",
        :headings => ['Module Stream','RPMs'],
        :rows => keep_rpms.reject{|k,v| v.empty?}.map do |k,v|
          keep_rpms_count += v.size
          [k,v.size]
      end)

      @log.debug2("REMOVING:\n#{rm_rpms.to_yaml}")
      @log.debug("KEEPING:\n#{keep_rpms.to_yaml}\n\n")
      @log.info("REMOVING #{rm_rpms_count} modular RPMs from #{rm_rpms.keys.size} module streams")
      @log.verbose("Summary of RPMs removed, per module stream\n#{modules_rm_summary}")
      @log.info("KEEPING #{keep_rpms_count} modular RPMs from #{keep_rpms.keys.size} module streams")
      @log.verbose("Summary of RPMs kept, per module stream:\n#{modules_keep_summary}")
      rebuild_modular_repo( modules_stream_path, fixed_mod_stream)
      @log.success("Fixed modulemd RPMs in '#{@short_repodir}'")
      return true
    else
      @log.happy("modulemd already correct in '#{@short_repodir}'")
    end

  rescue  StandardError => e
    if e.message =~ /\ANo 'modules' data/
      @log.info("Skipping repo '#{@short_repodir}' (not a modular repo)")
      return false
    end
    @log.error("#{e.message}\n\n#{e.backtrace.join("\n")}")
    @log.warn("Skipping repo '#{@short_repodir}' because of errors")
  end
end

class MultiSlimModuleMdsFixer
  def initialize(repos_root_dir:, logger:)
    @repos_root_dir = repos_root_dir
    @log = logger
  end

  def fix_modulemds_in_subdirs
    @log.info "== Fixing slimmed modulemd data in subdirs under #{@repos_root_dir}"
    Dir[File.join(@repos_root_dir,'*')].each do |repo_dir|
      @log.verbose "Processing subdir: #{repo_dir}"
      fixer = SlimModuleMdFixer.new(
        repo_dir: repo_dir,
        logger: @log,
      )
      fixer.slim_modulemd
    end
    puts "FINIS"
  end
end

repos_root_dir  = ARGV.first || '_download_path/build-6-6-0-centos-8-x86-64-repo-packages/'

repos_fixer = MultiSlimModuleMdsFixer.new(
  repos_root_dir: repos_root_dir,
  logger: get_logger( log_level: :verbose )
)
repos_fixer.fix_modulemds_in_subdirs
