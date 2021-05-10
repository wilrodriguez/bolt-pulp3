require 'yaml'
require 'pry'

output_file='repos_to_mirror--el7-iso.yaml'

packages_yaml_rpms_file = 'el7-iso.packages.yaml'
pkglist_rpms_file = 'el7-iso.pkglist.txt'

packages_yaml_rpms = YAML.load_file(packages_yaml_rpms_file)

# FIXME: handle pkglist RPMs


repos = {
  'pulp-el7-os'         => "http://mirror.centos.org/centos/7/os/x86_64/",
  'pulp-el7-extras'     => 'http://mirror.centos.org/centos/7/extras/x86_64/',
  'pulp-el7-epel'       => 'https://dl.fedoraproject.org/pub/epel/7/x86_64/',
  'pulp-el7-postgresql' => 'https://download.postgresql.org/pub/repos/yum/9.6/redhat/rhel-7-x86_64/',
  'pulp-el7-simp'       => 'https://download.simp-project.com/SIMP/yum/releases/latest/el/7Server/x86_64/simp/',
  'pulp-el7-puppet'     => 'https://yum.puppet.com/puppet6/el/7/x86_64/',
}


yy = packages_yaml_rpms.map do |k,v|
  if v[:source] =~ %r[/epel/7/]
    v[:_source] = v.delete(:source)
    v[:repo] = 'https://dl.fedoraproject.org/pub/epel/7/x86_64/'
  elsif v[:source] =~ %r[/centos/7/os/]
    v[:_source] = v.delete(:source)
    v[:repo] = 'http://mirror.centos.org/centos/7/os/x86_64/'
  elsif v[:source] =~ %r[/centos/7/extras/]
    v[:_source] = v.delete(:source)
    v[:repo] = 'http://mirror.centos.org/centos/7/extras/x86_64/'
  elsif v[:source] =~ %r[/simp-project/6_X_Dependencies/packages/el/7/]
    v[:_source] = v.delete(:source)
    v[:repo] = 'https://download.simp-project.com/SIMP/yum/releases/latest/el/7Server/x86_64/simp/'
    #v[:repo] = 'https://download.simp-project.com/SIMP/yum/releases/latest/el/7/x86_64/simp/' ## identical to 7Server??
  elsif v[:source] =~ %r[/puppet/el/7/] || v[:source] =~ %r[/puppet6/el/7/]
    v[:_source] = v.delete(:source)
    v[:repo] = 'https://yum.puppet.com/puppet6/el/7/x86_64/'
  elsif v[:source] =~ %r[/download\.postgresql\.org/pub/repos/yum/9.6/]
    v[:_source] = v.delete(:source)
    v[:repo] = 'https://download.postgresql.org/pub/repos/yum/9.6/redhat/rhel-7-x86_64/'
  end
  [k,v]
end.to_h

matched_rpms = yy.select{ |k,v| v[:repo] }
unmatched_rpms = yy.select{ |k,v| !v.key?(:repo) }

# steady on, syntastic
yy.inspect

matched_repo_urls = matched_rpms.map{|k,v| v[:repo]}.sort.uniq
known_repo_urls = repos.map {|repo,repo_url| repo_url }.sort.uniq

missing_urls = matched_repo_urls - known_repo_urls
unless missing_urls.empty?
  fail "Matched RPMS included unknown/unlabeled repos:\n\t#{missing_urls.join("\n\t")}\n"
end

missing_urls = known_repo_urls - matched_repo_urls
unless missing_urls.empty?
  fail "Known repo URLs not present in matched RPMS:\n\t#{missing_urls.join("\n\t")}\n"
end

data = repos.map  do |repo_name, repo_url|
  rpms = matched_rpms.select{|k,v| v[:repo] == repo_url }
  [repo_name, {
    'url' => repo_url,
    'rpms' => rpms.keys, # TODO do we need versions, etc?
  }]
end.to_h

pkglist_rpms_file.inspect

puts
File.open(output_file,'w'){|f| f.puts data.to_yaml }
require 'pry'; binding.pry

# FIXME: handle unmatched/special case RPMs
unless unmatched_rpms.empty?
  fail ["FIXME: unhandled RPMs:",'',
    "These RPMs did not match any repos, and we have not yet implemented logic to deal with them as one-offs:",
    '', unmatched_rpms.to_yaml.gsub(/^/,'    '), ''].join("\n")
end

