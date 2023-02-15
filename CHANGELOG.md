# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added

- Add support for `modulemd_defaults`
- Update to Pulp 3:19
  - Set `retain_repo_versions` and `retain_package_versions` for speed
- Fix broken version constraint logic, tolerate operator-less versions
- Make env path safe for Bolt's built-in `bundler`
- New optional global `_options` key for bolt_pulp3_config file
  - New option: `default_destination_repo_baseurl`
- Add the suffix `--simp` to the titles of all repos in
  `simp-and-all-deps.repos` (avoids collisions with disabled repos)

- Container volume support
- New plan `pulp3::in_one_container::get_logs`, to fetch and review django logs
  from inside the running Pulp container
- Created `CHANGELOG.md` for project
- Updated RPMs in `build/**/*.yaml` files

### Changed

- Cleaned up root directory, gem deps, Bolt project
- Internal code simplifications

### Removed

- (Incomplete) never-used plans `::rpm::mirror` and `::rpm::repo`

### Fixed

- Filter for podman matching
- Container destruction
- Bumped the pulp image to fix EPEL issues
- Mirrored Module streams did not have default profiles or groups

## [0.3.0] - 2021-08-26

### Added

* Bolt project & scripts ready for sharing with the team

## [0.2.0] - 2021-08-11

### Added

* `slim_modular_repodata_fix.rb` script to correct post-slimmed modulemd data

## [0.1.0] - 2021-05-20

### Added

* Initial working direct download + Pulp uploads

[0.1.0]: https://github.com/op-ct/puppetsync/releases/tag/0.1.0
[0.2.0]: https://github.com/op-ct/puppetsync/compare/0.1.0...0.2.0
[0.3.0]: https://github.com/op-ct/puppetsync/compare/0.2.0...0.3.0
[Unreleased]: https://github.com/op-ct/puppetsync/compare/0.3.0...HEAD
