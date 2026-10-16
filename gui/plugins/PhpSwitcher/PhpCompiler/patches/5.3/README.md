# Patches for PHP 5.3.29

Most of patches were imported from Debian repository.

## Added patches

- nxw-freetype2_path.patch:
    - Fix for new freetype2 header location
- nxw-ftbfs_tidy_html5.patch:
    - Add support for the new tidy-html5 library
- nxw-openssl_no_ssl3.patch:
    - Check for SSL 3 support in linked OpenSSL library
- nxw-XMLRPC-EPI-library-has-to-be-linked-as-lxmlrpc-epi.patch:
    - Link XMLRPC-EPI library has -lxmlrpc-epi
- nxw-fix_gd_210.patch:
    - Fix php-gd compatibility with libgd2 2.1.0
- nxw-gmp_path.patch:
    - Multiarch support
- nxw-curl_path.patch:
    - Multiarch support
- nxw-fix_broken_openssl_pkg_config_test.patch:
    - Fix broken openssl pkg-config test
- nxw-openssl_1.1_compatibility.patch:
    - Add support for OpenSSL 1.1
- nxw-use-pkg-config-for-libxml2.patch:
    - Use pkg-config for libxml2
- nxw-newest-icu-compatibility.patch:
    - Use pkg-config for ICU
    - Use ICU namespace for >= ICU 63.1
    - Amend C++11 for intl compilation on older distributions
- nxw-imscp-quirks.patch:
    - Added modules.ini file for loading of various PHP shared extensions
    - Updated PHP FPM master configuration file:
        - pid: @EXPANDED_LOCALSTATEDIR@/run/phpswitcher/psw5.3-fpm.pid
        - error_log: @EXPANDED_LOCALSTATEDIR@/log/phpswitcher/psw5.3-fpm.log
        - syslog.ident: psw5.6-fpm
        - emergency_restart_threshold: 10
        - emergency_restart_interval: 1m
        - process_control_timeout: 60s
        - daemonize: yes
        - Added include statement for FPM pool configuration file
- nxw-newest-libedit-compatibility.patch:
    - Fix rl_completion_matches compilation with newer libedit
- nxw-remove_unwanted_links_in_standard_info.patch:
    - Remove unwanted links in standard PHP info

## Disabled patches

- 001-libtool_fixes.patch: Irrelevant 
- libtool2.2.patch: Irrelevant 
- 007-extension_api.patch: Debian specific (installation layout)
- 031-expose_all_built_and_installed_apis.patch: Debian specific
- 033-we_WANT_libtool.patch: Irrelevant 
- 113-php.ini_securitynotes.patch: Debian specific
- php-fpm-man-section-and-cleanup.patch: Debian specific (installation layout)
- fpm-config.patch: Debian specific (installation layout)
- session_save_path.patch: Debian specific (installation layout)
- php-fpm-sysconfdir.patch: Debian specific (installation layout)

## Modified patches

- 0003-debian_quirks.patch: Removed changes for debian installation layout
- libtool2.2.patch: Updated libtool path
