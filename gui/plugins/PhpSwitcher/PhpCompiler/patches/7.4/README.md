# Patches for PHP 7.4.0RC1

Most of patches were imported from Debian
[PHP team git repository](https://salsa.debian.org/php-team/php/tree/master-7.4).

## Added patches

- 0041-nxw-imscp_quirks.patch:
    - Added modules.ini file for loading of various PHP shared extensions
    - Updated PHP FPM master configuration file:
        - pid: @EXPANDED_LOCALSTATEDIR@/run/phpswitcher/psw7.4-fpm.pid
        - error_log: @EXPANDED_LOCALSTATEDIR@/log/phpswitcher/psw7.4-fpm.log
        - syslog.ident: psw7.4-fpm
        - emergency_restart_threshold: 10
        - emergency_restart_interval: 1m
        - process_control_timeout: 60s
        - daemonize: yes
- 0042-nxw-PEAR-installation-failure.patch:
    - Hide warnings due to stream_set_option() not implemented in PHP_Archive
      See #78461
- 0043-nxw-remove_unwanted_links_in_standard_info.patch:
    - Remove unwanted links in standard PHP info

## Disabled patches

- 0001-libtool_fixes.patch: Irrelevant
- 0004-extension_api.patch: Debian specific (installation layout)
- 0006-php.ini_securitynotes.patch: Debian specific
- 0011-qdbm-is-usr_include_qdbm.patch: Changes were integrated in RC3
- 0012-session_save_path.patch: Debian specific (installation layout)
- 0013-php-fpm-man-section-and-cleanup.patch: Debian specific (installation layout)
- 0014-fpm-config.patch: Debian specific (installation layout)
- 0015-php-fpm-sysconfdir.patch: Debian specific (installation layout)
- 0024-expose_all_built_and_installed_apis.patch: Debian Specific
- 0028-php-5.4.8-ldap_r.patch: No longer needed (since PHP 7.4.0RC2)

## Modified patches

- 0002-debian_quirks.patch: Removed changes for debian installation layout
