# Patches for PHP 7.3.9

Most of patches were imported from Debian
[PHP team git repository](https://salsa.debian.org/php-team/php/tree/master-7.3).

## Added patches

- 0049-nxw-imscp-quirks.patch:
    - Added modules.ini file for loading of various PHP shared extensions
    - Updated PHP FPM master configuration file:
        - pid: @EXPANDED_LOCALSTATEDIR@/run/phpswitcher/psw5.6-fpm.pid
        - error_log: @EXPANDED_LOCALSTATEDIR@/log/phpswitcher/psw5.6-fpm.log
        - syslog.ident: psw5.6-fpm
        - emergency_restart_threshold: 10
        - emergency_restart_interval: 1m
        - process_control_timeout: 60s
        - daemonize: yes
- 0050-nxw-remove_unwanted_links_in_standard_info.patch:
    - Remove unwanted links in standard PHP info

## Disabled patches

- 0001-libtool_fixes.patch: Irrelevant
- 0004-libtool2.2.patch: Irrelevant
- 0005-we_WANT_libtool.patch: Irrelevant
- 0007-extension_api.patch: Debian specific (installation layout)
- 0011-php.ini_securitynotes.patch: Debian specific
- 0018-session_save_path.patch: Debian specific (installation layout)
- 0019-php-fpm-man-section-and-cleanup.patch: Debian specific (installation layout)
- 0020-fpm-config.patch: Debian specific (installation layout)
- 0021-php-fpm-sysconfdir.patch: Debian specific (installation layout)
- 0031-expose_all_built_and_installed_apis.patch: Debian specific

## Modified patches

- 0003-debian_quirks.patch:
    - Removed changes for debian installation layout
- 0004-libtool2.2.patch:
    - Updated libtool path
