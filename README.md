# Proof-of-concept Pulp3 Bolt project + modular repo mirror-slimmer

<!-- vim-markdown-toc GFM -->

* [Overview](#overview)

<!-- vim-markdown-toc -->

## Overview

This repo presently contains a mishmash of at least two projects:

1. A Bolt project to automate the prep/spin-up + destruction of Pulp3's
   "Pulp-in-one-container":

   ```sh
   # Use Bolt as a package, not as a RubyGem
   command -v rvm && rvm use system

   # Install deps
   /opt/puppetlabs/bolt/bin/bolt module install --force      # install modules
   /opt/puppetlabs/bolt/bin/gem install --user gem.deps.rb   # install RubyGems

   # See options for the spin up/destroy plans
   /opt/puppetlabs/bolt/bin/bolt plan show pulp3::in_one_container
   /opt/puppetlabs/bolt/bin/bolt plan show pulp3::in_one_container::destroy files=true force=true
   ```

2. A super-hacky proof-of-concept ruby script (`do.rb`) that uses Pulp to
   mirror, slim, and output data/scripts to download a release's required RPMs
   into modular-safe "slim" repos.

   ```sh
   # See options for the ruby script
   /opt/puppetlabs/bolt/bin/ruby do.rb --help

   # Use Pulp
   /opt/puppetlabs/bolt/bin/ruby do.rb -f build/6.6.0/CentOS/7/x86_64/repo_packages.yaml

   # Reposync all repos from the latest do.rb run to directory `_download_path/`
   bash _slim_repos.sh
   ```

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

