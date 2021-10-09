# Proof-of-concept Pulp3 Bolt project + modular repo mirror-slimmer

<!-- vim-markdown-toc GFM -->

* [Overview](#overview)
  * [Setup](#setup)
    * [Setup Requirements](#setup-requirements)
      * [OS requirements](#os-requirements)
      * [OS Storage requirements](#os-storage-requirements)
      * [Runtime dependencies](#runtime-dependencies)
      * [Avoiding conflicts with RubyGems/RVM](#avoiding-conflicts-with-rubygemsrvm)
    * [Initial setup](#initial-setup)
    * [Beginning with the repo slimmer](#beginning-with-the-repo-slimmer)
  * [Usage](#usage)
    * [(Bolt) Provisioning the Pulp container](#bolt-provisioning-the-pulp-container)
    * [(Script) `slim-pulp-repo-copy.rb` - Use Pulp to create slim repo mirrors](#script-slim-pulp-repo-copyrb---use-pulp-to-create-slim-repo-mirrors)
    * [(Script) `_*.reposync.sh`: Mirror all slim repos into a local directory](#script-_reposyncsh-mirror-all-slim-repos-into-a-local-directory)
    * [(You) Taking the repos and building SIMP](#you-taking-the-repos-and-building-simp)
    * [(Bolt) Destroying the Pulp container](#bolt-destroying-the-pulp-container)
      * [Destroying container, but preserving volumes (persists Pulp data)](#destroying-container-but-preserving-volumes-persists-pulp-data)
      * [Destroying both container + volumes w/data (wipes Pulp clean)](#destroying-both-container--volumes-wdata-wipes-pulp-clean)

<!-- vim-markdown-toc -->

## Overview

This repo contains tools to create a full (probably repo-closed) "slim" copy of
all upstream yum repos required to support a self-contained SIMP release.

This includes:

* Bolt plans to provision, configure, and destroy a local
  [Pulp-in-one-container]
* A Ruby script:
  1. `slim-pulp-repo-copy.rb` ― uses Pulp to create, copy, and depsolve all
     desired RPMs from upstream repos into "slim" repo mirrors

<!--
This repo presently contains a mishmash of several projects that aid the same workflow:

1. A Bolt project to automate the prep/spin-up + destruction of Pulp3's
   "Pulp-in-one-container":

2. A super-hacky proof-of-concept ruby script (`slim-pulp-repo-copy.rb`) that uses Pulp to
   mirror, slim, and output data/scripts to download a release's required RPMs
   into modular-safe "slim" repos.

   **Note:** this script was originally a simple MVP proof-of-concept script
   to see if we could automate the Pulp API, but scheduling & circumstances
   have jammed an entire RELENG tool on top of that (in a single, hideous
   mega-class), resulting in the labyrinthine effrontery you see here.

   It is NOT a productized tool and will need to be refactored (possibly
   puppetized) before adding it to the RELENG tool suite.
-->

### Setup

#### Setup Requirements

The following components are needed to use all the features of this project.

##### OS requirements

* [Puppet Bolt 3.12+][bolt], installed from an [official OS package][bolt-install] (DO NOT use a `bolt` gem installed by RubyGems)
  * Instructions for [installing Puppet Bolt][bolt-install] ([RHEL-specific
    instructions][bolt-install-rhel])

* The [podman] or [docker] runtimes are required to run the Pulp-in-one-container:
  * [installing podman on el8]
  * [installing podman on el7]
  * [installing docker on centos]
  * [installing docker on fedora]

* OS commands that must be available to locally mirror repos in later scripts:

  * `dnf reposync`

  On EL7, you can install these commands with:

    ```
    sudo yum install -y dnf-plugins-core
    ```

* You may also need to install `gcc` in order for Bolt to compile native ruby
  gems during `/opt/puppetlabs/bolt/bin/gem install --user-install -g gem.deps.rb`:

  * `gcc`

  On EL7, you can install these commands with:

    ```
    sudo yum install -y gcc
    ```

##### OS Storage requirements

* Mirroring repos can take a lot of disk space.  Even with `on_demand`
  mirroring and slim repo copy, the combined container image, overlays, and
  volumes for a single OS's mirrors can exceed 5 GB.  Reposyncing the files to
  the local filesystem will take at least 1.4 GB.
* Container storage is provisioned with `{docker|podman} volume create`.
  If your local docker/podman's `graphRoot` resides on a small disk partition,
  there is a risk that a single run will fill it.  This is of particular
  concern when running docker under /var/lib/docker when it resides on the
  system's `/` or `/var` partition.

##### Runtime dependencies

These dependencies can be installed by Bolt (see the [Initial
setup](#initial-setup) section)

  * Puppet modules (defined in bolt project's `bolt-project.yaml`)
  * Ruby Gems (defined in `gem.deps.rb`)

##### Avoiding conflicts with RubyGems/RVM

The project was designed to run from a clean environment, starting with the
OS-packaged bolt. If you use RubyGems/RVM in your environment, make sure that
your session:

* ONLY uses the `bolt` executable/libraries that have been installed from an
  [official OS package][bolt-install]
* Does NOT use the `bolt` executable/libraries installed by RubyGems
* Does NOT use an RVM-managed version of Ruby (it overwrites gem paths and
  conflicts with the OS bolt)

If you use RVM, make sure you always run `rvm use system` before running `bolt`
with this project.

#### Initial setup

1. Install any packages needed to provide the
   [OS requirements](#os-requirements).

2. Before running any plans for the first time, run these commands from the top
   level of this repository:

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

#### (Script) `slim-pulp-repo-copy.rb` - Use Pulp to create slim repo mirrors

Mirror, filter, and resolve upstream repos into new "slim" repos for a distro:


**Usage**

```sh
# See options for the ruby script
./slim-pulp-repo-copy.rb --help

# Use Pulp to create slim versions of upstream repos
./slim-pulp-repo-copy.rb --repos-rpms-file build/6.6.0/CentOS/8/x86_64/repo_packages.yaml
```

After the script completes, run the following to check if there were problems
while resolving RPM dependencies during the Advanced RPM Copy:

```sh

pulp3::in_one_container::get_log
grep -v -E '_call_with_frames_removed|Attempting to start' downloads/logs/pulp/django-info.log | grep -E 'WARNING'
```


**Input file**

* A `repo_packages.yaml` file for a SIMP release (ex:
  `build/6.6.0/CentOS/8/x86_64/repo_packages.yaml`)

**Output files**

The script will create helper files under the `output/` directory (the names
will change based on the input file used):

| Output File                        | Purpose                                                                                                   |
| ---                                | ---                                                                                                       |
| **`_slim_repos.*.reposync.sh`**    | Script pre-configured to mirror all the recently-created slim repos into local `_download_path` directory |
| **`_slim_repos.*.repoclosure.sh`** | Pre-builit reposync command for all repos (EL7 only; cannot help with modular repos)                      |
| **`_slim_repos.*.repo`**           | YUM `.repo` file, containing all slim repos that were created                                             |
| **`_slim_repos.*.versions.yaml`**  | Basic SBOM summary of each package from each repository                                                   |
| **`_slim_repos.*.api_items.yaml`** | Debug data, detailing the Pulp API URIs of the slim repos that were created                               |


#### (Script) `_*.reposync.sh`: Mirror all slim repos into a local directory

Run the `_*.reposync.sh` script created by `slim-pulp-repo-copy.rb` to mirror
all of its repos and metadata into a local directory.

**Usage**

```sh
bash output/_slim_repos.build-6-6-0-centos-8-x86-64-repo-packages.reposync.sh
```

**Output**

The script creates:
* a local `_download_path/` directory
* a subdirectory for the distro being mirrored (e.g.,
  `build-6-6-0-centos-8-x86-64-repo-packages/`)
* a directory containing a local mirror of each repo (e..g, `appstream/`,
  `epel/`)

The `_download_path/` directory can contain multiple distros. If you mirror a
centos7 and centos8 distro and run the `_*.reposync.sh` scripts they both
generate, you will end up with a directory structure like this:

```
_download_path/
├── build-6-6-0-centos-7-x86-64-repo-packages/
│   ├── epel/
│   ├── extras/
│   ├── os/
│   ├── postgresql/
│   ├── puppet/
│   └── simp/
└── build-6-6-0-centos-8-x86-64-repo-packages/
    ├── AppStream/
    ├── BaseOS/
    ├── epel/
    ├── epel-modular/
    ├── extras/
    ├── postgresql/
    ├── PowerTools/
    └── puppet/
```


#### (You) Taking the repos and building SIMP

If the repos contain 100% of the distro RPMs you need, you can simply copy the
mirrored repo directory onto the SIMP ISO or SIMP server.  Copy ALL the files
as they are (or mirror them with `dnf reposync --download-metadata`), and you
will still have working yum repositories.  For modular repos, their modular
metadata will remain intact.


#### (Bolt) Destroying the Pulp container

The `pulp3::in_one_container::destroy` plan will destroy the
Pulp-in-one-container and―optionally―its volumes and data:

##### Destroying container, but preserving volumes (persists Pulp data)

Note: This keeps all of Pulp's state (database files, pids, mirrored repo data)
intact.  If you provision another container, it will re-mount and re-use this
data

```sh
bolt plan run pulp3::in_one_container::destroy
```


##### Destroying both container + volumes w/data (wipes Pulp clean)

Note: This DESTROYS all of Pulp's state (database files, pids, mirrored repo
data) intact.  If you provision another container, it will re-mount and re-use
this data


```sh
bolt plan run pulp3::in_one_container::destroy volumes=true [force=true]
```




[Pulp-in-one-container]: https://pulpproject.org/pulp-in-one-container/
[bolt]: https://puppet.com/docs/bolt/latest/bolt.html
[puppet]: https://puppet.com/docs/puppet/latest/
[bolt-install]: https://puppet.com/docs/bolt/latest/bolt_installing.html
[bolt-install-rhel]: https://puppet.com/docs/bolt/latest/bolt_installing.html#install-bolt-on-rhel
[podman]: https://podman.io
[installing podman on el8]: https://podman.io/getting-started/installation#rhel8
[installing podman on el7]: https://podman.io/getting-started/installation#rhel7
[docker]: https://docker.io
[installing docker on centos]: https://docs.docker.com/engine/install/centos/
[installing docker on fedora]: https://docs.docker.com/engine/install/fedora/
