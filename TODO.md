

<!-- vim-markdown-toc GFM -->

* [Issues](#issues)
* [`do.rb` issues](#dorb-issues)
* [Pulp3 issues](#pulp3-issues)
  * [Advanced repo copy can result in broken module streams/profiles](#advanced-repo-copy-can-result-in-broken-module-streamsprofiles)
  * [SIMP-9729 - Advanced repo copy performs repoclose on modular repository packages, but can silently fail](#simp-9729---advanced-repo-copy-performs-repoclose-on-modular-repository-packages-but-can-silently-fail)
* [Upstream Repository issues](#upstream-repository-issues)
  * [epel-modular broken](#epel-modular-broken)

<!-- vim-markdown-toc -->


## Issues

## `do.rb` issues



## Pulp3 issues

### Advanced repo copy can result in broken module streams/profiles

Advanced copy with EL8 nodejs 10

Possibly Related:
* https://pulp.plan.io/issues/5055 [EPIC] Ursine RPM Copy dependencies on modular RPMS from Default Modules needs to be added 
  _Added by bherring almost 2 years ago. Updated 5 months ago._

### SIMP-9729 - Advanced repo copy performs repoclose on modular repository packages, but can silently fail

* NOTE: So far, I have only seen this happen with EL8 modular repositories.  So far, EL7 always repocloses.
* The failing repoclosure can be verified by running `dnf repoclosure` on all
  the destination repos involved in the advanced repo copy.
* TODO BUG: The unresolved RPMs are not always noted in warnings in the Pulp
  server's django log.


## Upstream Repository issues

### epel-modular broken

Between May 21 and May 24 2021, the `389-ds-base-legacy-tools` package was
removed from the (EL8) `epel-modular` repository.  However, the package is
still in the modulemd metadata for `389-directory-server:stable/legacy`, which
breaks a `module install`:


```console
[root@a72c32acaa8f /]# dnf module info 389-directory-server:stable --profile
Failed to set locale, defaulting to C.UTF-8
Last metadata expiration check: 0:42:20 ago on Mon May 24 17:54:12 2021.
Name    : 389-directory-server:stable:820210507090527:9edba152:x86_64
default : 389-ds-base
        : cockpit-389-ds
legacy  : 389-ds-base
        : 389-ds-base-legacy-tools
        : cockpit-389-ds
minimal : 389-ds-base

[root@a72c32acaa8f /]# dnf module install 389-directory-server:stable/legacy
Failed to set locale, defaulting to C.UTF-8
Last metadata expiration check: 0:43:53 ago on Mon May 24 17:54:12 2021.
Error:
 Problem: package 389-ds-base-1.4.4.15-2.module_el8+12008+be90a417.x86_64 obsoletes 389-ds-base-legacy-tools < 1.4.4.6 provided by 389-ds-base-legacy-tools-1.4.3.8-7.module_el8.3.0+752+5796e55d.x86_64
  - conflicting requests
(try to add '--skip-broken' to skip uninstallable packages or '--nobest' to use not only best candidate packages)
```


The version of `389-ds-base-legacy-tools` in AppStream is older (1.4.3.8-7) than the one that was in epel-modular (1.4.3.22-1).

