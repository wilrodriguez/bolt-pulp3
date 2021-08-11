#!/opt/puppetlabs/bolt/bin/ruby
# TODO: use pulp labels to identify repo build session/purpose for cleanup/creation

require 'yaml'
require 'fileutils'
require 'tempfile'
require 'nokogiri'


class SlimModuleMdFixer
  def initialize(repo_dir:, logger:)
    @repo_dir = repo_dir
    @log = logger
    @repodata_dir = File.join(@repo_dir,'repodata')
    File.directory?(@repodata_dir) || fail("No repodata/ dir at '#{@repodata_dir}'")
    @repomd_xml = File.join(@repodata_dir,'repomd.xml')
    File.file?(@repomd_xml) || fail("No repomd.xml at '#{@repomd_xml}'")
    @log.info( @repomd_xml )
  end


  require 'zlib'
  def gunzip(data)
    window_size = Zlib::MAX_WBITS + 16 # decode only gzip
    Zlib::Inflate.new(window_size).inflate(data)
  end


  def load_repomd_data_file(path)
    if File.basename(path).split('.').last =~ /\A(yaml|yml)\Z/
      return YAML.load_stream(File.read(path))
    end

    if File.basename(path).split('.')[-2..-1] ==  ["xml", "gz"]
      return( Nokogiri::XML.parse(gunzip(File.read(path))) )
    end
    raise("Don't know how to read type of file at '#{path}'")
  end

  def get_repomd_xml_data_path(doc, type)
    doc = doc.dup
    doc.remove_namespaces! # bad form, but there's only one and I'm in a hurry
    _path = doc.xpath(%Q[//data[@type="#{type}"]/location/@href]).text
    fail("can't find '#{type}' data in #{@repomd_xml}") if _path.empty?
    path = File.join(@repo_dir,_path)
    File.file?(path) || fail("No #{type} file at '#{modules_yaml}'")
    path
  end

  def slim_modulemd(repo_dir)
    doc = Nokogiri::XML.parse( File.read(@repomd_xml) )
    modules_stream_path = get_repomd_xml_data_path(doc, 'modules')

    modules_stream = load_repomd_data_file(path)
    filelists_doc = load_repomd_data_file(get_repomd_xml_data_path(doc, 'filelists'))
    primary_doc = load_repomd_data_file(get_repomd_xml_data_path(doc, 'primary'))

    fixed_mod_stream = modules_stream.map do |mod_stream|
      rpms = mod_stream['data']['artifacts']['rpms']
      new_rpms = rpms.select do |rpm|
        next(nil) if rpm =~ /\.src\Z/
        nevra = rpm.match(/\A(?<name>.+?)-(?<epoch>\d+):(?<ver>.+?)-(?<rel>\d+.*)\.(?<arch>[^.]+)\Z/)

        unless nevra
          @log.error("Could not parse NEVRA from rpm name: #{rpm}")
          require 'pry'; binding.pry
        end
        conditions = nevra.named_captures.map {|k,v| "xmlns:version/@#{k}='#{v}'" }.join(' and ')
        e = primary_doc.xpath("//xmlns:package[xmlns:name='#{nevra[:name]}' and #{conditions} ]", primary_doc.namespaces)
        !e.empty?
      end
      mod_stream['data']['artifacts']['rpms'] = new_rpms
      mod_stream
    end

    backup_modules_stream_path = "#{modules_stream_path}.#{Time.now.strftime("%F")}"
    FileUtils.cp modules_stream_path, backup_modules_stream_path, verbose: true

    fixed_mod_stream_yaml = YAML.dump_stream(*fixed_mod_stream)
    #File.open(modules_stream_path,'w'){|f| f.puts fixed_mod_stream}
    # TODO 
    # - [ ] write modules.yaml
    # - [ ] re-build repo with createrepo_c - OR - update repomd.xml with the right values

  require 'pry'; binding.pry

  end
end

repo_dir  = ARGV.first || '_download_path/build-6-6-0-centos-8-x86-64-repo-packages/appstream/'

def get_logger(log_file: 'rpm.slim_modulemd_repodata_fix.log', log_level: :debug)
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

  log = Logging.logger[SlimModuleMdFixer]
  log.add_appenders(
    Logging.appenders.stdout(
      layout: Logging.layouts.pattern(color_scheme: 'bright'),
      level: log_level
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
  log
end


fixer = SlimModuleMdFixer.new(
  repo_dir: repo_dir,
  logger: get_logger,
)

fixer.slim_modulemd(repo_dir)
