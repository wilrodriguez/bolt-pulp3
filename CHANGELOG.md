# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added

- `CHANGELOG.md`
- `Rakefile` & tasks for
- Updated RPMs

### Changed

- Reworked volumes
- Cleaned up root directory

### Fixed

- Filter for podman matching
- Container destruction
- Bumped the pulp image to 3.15 to fix EPEL issues

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
