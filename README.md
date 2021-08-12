# Proof-of-concept Pulp3 Bolt project + modular repo mirror-slimmer

<!-- vim-markdown-toc GFM -->

* [Overview](#overview)
  * [Setup](#setup)
    * [Setup Requirements](#setup-requirements)
    * [Initial setup](#initial-setup)
    * [Beginning with the repo slimmer](#beginning-with-the-repo-slimmer)
  * [Usage](#usage)
    * [(Bolt) Provisioning the Pulp container](#bolt-provisioning-the-pulp-container)
    * [(Script) `pulp-slim-repo-copy.rb` - Use Pulp to create slim repo mirrors](#script-pulp-slim-repo-copyrb---use-pulp-to-create-slim-repo-mirrors)
    * [(Script) `_*.reposync.sh`: Mirror all slim repos into a local directory](#script-_reposyncsh-mirror-all-slim-repos-into-a-local-directory)
    * [(Script) `slim-modular-repodata-fix.rb`: Fix modulemd data in local slim repos](#script-slim-modular-repodata-fixrb-fix-modulemd-data-in-local-slim-repos)
    * [(You) Taking the repos and building SIMP](#you-taking-the-repos-and-building-simp)
    * [(Bolt) Destroying the Pulp container](#bolt-destroying-the-pulp-container)
      * [Destroying container, but preserving mount data (persist Pulp data)](#destroying-container-but-preserving-mount-data-persist-pulp-data)
      * [Destroying both container and mounts w/state files (reset Pulp data)](#destroying-both-container-and-mounts-wstate-files-reset-pulp-data)

<!-- vim-markdown-toc -->

## Overview


### Setup


#### Setup Requirements

* [Puppet Bolt 3.12+][bolt], installed from an [OS package][bolt-install]
  * EL7/EL7/Fedora RPM: `puppet-bolt`
  * **Note:** Use the Bolt installation provided by the OS package; DO NOT use
    a bolt gem installed by RubyGems

* Some EL commands must be available to download and fix
  `modules.yaml` in later scripts:
  * `modifyrepo_c` (EL7 RPMs: `modifyrepo_c`)
  * `dnf reposync` (EL7 RPMs: `dnf-plugins-core`)

* Runtime dependencies, installed with Bolt (see next section):
  * Puppet modules (defined in bolt project's `bolt-project.yaml`)
  * Ruby Gems (defined in `gem.deps.rb`)

#### Initial setup

1. Install any OS packages needed to provide the requirements listed above

2. Before running any plans, from the top level of this repository:

```sh
# RVM users: make sure you're running the OS-installed `bolt`, and not a gem:
command -v rvm && rvm use system

# Install dependencies
/opt/puppetlabs/bolt/bin/bolt module install --force        # install Puppet modules
/opt/puppetlabs/bolt/bin/gem install --user -g gem.deps.rb  # install RubyGems

 # Verify `pulp3::` plans are visible
bolt plan show

# See options for the provision / destroy plans
/opt/puppetlabs/bolt/bin/bolt plan show pulp3::in_one_container
/opt/puppetlabs/bolt/bin/bolt plan show pulp3::in_one_container::destroy

```


#### Beginning with the repo slimmer

If you use RVM, make sure you always run `rvm use system` before proceeding,
so you use the Bolt installation provided by the OS package.


### Usage

#### (Bolt) Provisioning the Pulp container

```sh
# Run plan to provision Pulp-in-one-container from scratch
bolt plan run pulp3::in_one_container
```

#### (Script) `pulp-slim-repo-copy.rb` - Use Pulp to create slim repo mirrors

Mirror, filter, and resolve upstream repos into new "slim" repos for a distro:

```sh
# See options for the ruby script
./pulp-slim-repo-copy.rb --help

# Use Pulp to create slim versions of upstream repos
./pulp-slim-repo-copy.rb --create-new --repos-rpms-file build/6.6.0/CentOS/8/x86_64/repo_packages.yaml
```

Run `ls -lart` to see the log files the run created.  A finished run will
create helper files (the names will change based on the file you used):

* `_slim_repos.build-6-6-0-centos-8-x86-64-repo-packages.reposync.sh`: Script
  pre-configured to mirror all the recently-created slim repos into local
  `_download_path` directory
* `_slim_repos.build-6-6-0-centos-8-x86-64-repo-packages.repoclosure.sh`:
  Pre-build reposynce CLI (EL7 only; cannot help with modular repos)
* `_slim_repos.build-6-6-0-centos-8-x86-64-repo-packages.versions.yaml`: Basic
  SBOM summary of each package from each repository
* `_slim_repos.build-6-6-0-centos-8-x86-64-repo-packages.api_items.yaml`: Debug
  data, with Pulp API URIs of the slim repos that were created


#### (Script) `_*.reposync.sh`: Mirror all slim repos into a local directory

Run the `_*.reposync.sh` script created by a `slim_repo_copy.rb` session to
mirror all of its repos and metadata.

```sh
bash _slim_repos.build-6-6-0-centos-8-x86-64-repo-packages.reposync.sh
```

This will mirror all repos for the distro into a local `_download_path/`
directory, with a subdirectory for the distro being mirrored.  If you mirror a
centos7 and centos8 distro and run both of their `..reposync.sh` scripts, you
will end up with a directory structure like this:

```
_download_path2
├── build-6-6-0-centos-7-x86-64-repo-packages
│   ├── epel
│   ├── extras
│   ├── os
│   ├── postgresql
│   ├── puppet
│   └── simp
└── build-6-6-0-centos-8-x86-64-repo-packages
    ├── appstream
    ├── baseos
    ├── epel
    ├── epel-modular
    ├── extras
    ├── postgresql
    └── puppet
```

#### (Script) `slim-modular-repodata-fix.rb`: Fix modulemd data in local slim repos

This fixes modular repos' slimmed RPM metadata in the repos downloaded under
`_download_path/<namespace>/` that was created by the `.reposync.sh` script(s):

```sh
./slim-modular-repodata-fix.rb [ROOT_DIR_OF_REPOS]
```

`[ROOT_DIR_OF_REPOS]` defaults to `_download_path/build-6-6-0-centos-8-x86-64-repo-packages/`

You don't need to run `slim-modular-repodata-fix.rb` for EL7, because it
doesn't have any modular repos.


#### (You) Taking the repos and building SIMP

If the repos contain 100% of the distro RPMs you need, you can simply copy the
mirrored repo directory onto the SIMP ISO or SIMP server.  Copy ALL the files
as they are (or mirror them with `dnf reposync --download-metadata`), and you
will still have working yum repositories.  For modular repos, their modular
metadata will remain intact.


#### (Bolt) Destroying the Pulp container

The `pulp3::in_one_container::destroy` plan will destroy the
Pulp-in-one-container and―optionally―all of its mounts and state data:

##### Destroying container, but preserving mount data (persist Pulp data)

Note: This destroys the keeps all of Pulp's state (database files, pids, mirrored rpeo data)
intact.  If you provision another container, it will re-mount and re-use this
data

```sh
bolt plan run pulp3::in_one_container::destroy
```


##### Destroying both container and mounts w/state files (reset Pulp data)

```sh
bolt plan run pulp3::in_one_container::destroy \
  force=true \
  files=true \
  --sudo-password-prompt
```

The `--sudo-password-prompt` is necessary because docker/podman will have
created some files as `root` or other UIDs and it is more convenient to
remove them all as superuser than to map each mount's path inside the container
and wipe them from there (also, this will still work after the container is
destroyed).



This repo presently contains a mishmash of several projects that aid the same workflow:

1. A Bolt project to automate the prep/spin-up + destruction of Pulp3's
   "Pulp-in-one-container":

2. A super-hacky proof-of-concept ruby script (`pulp-slim-repo-copy.rb`) that uses Pulp to
   mirror, slim, and output data/scripts to download a release's required RPMs
   into modular-safe "slim" repos.




   Output files include:
   * A `.sh` script to download all the slim repos
   * A DNF `.config` file with all repos,
   * An early attempt at release SBOM content in a `.yaml` file.

   **Note:** this script was originally a simple MVP proof-of-concept script
   to see if we could automate the Pulp API, but scheduling & circumstances
   have jammed an entire RELENG tool on top of that (in a single, hideous
   mega-class), resulting in the labyrinthine effrontery you see here.

   It is NOT a productized tool and will need to be refactored (possibly
   puppetized) before adding it to the RELENG tool suite.

[bolt]: https://puppet.com/docs/bolt/latest/bolt.html
[puppet]: https://puppet.com/docs/puppet/latest/
[bolt-install]: https://puppet.com/docs/bolt/latest/bolt_installing.html
