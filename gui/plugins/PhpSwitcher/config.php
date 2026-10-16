<?php
/**
 * i-MSCP PhpSwitcher plugin
 *
 * @author Laurent Declercq <l.declercq@nuxwin.com>
 * @copyright (C) 2014-2019 Laurent Declercq <l.declercq@nuxwin.com>
 * @license i-MSCP License <https://www.i-mscp.net/license-agreement.html>
 */

return [
    // phpinfo (default: true)
    // If enabled, customers will have access to configuration information
    // of various PHP versions through their UI. For the Fcgid server, static
    // PHP info files are generated while for the FPM server, PHP configuration
    // information are served at runtime, through the default FPM www.conf pool
    // of each PHP version.
    'phpinfo'  => true,

    // PLEASE, DON'T CHANGE ANY PARAMETER BELOW WIHTOUT KNOWING WHAT YOUR'RE
    // DOING. A MISTAKE COULD LEAD TO SEVERE DATA LOSS, OR SERVICES DISRUPTION.

    // Parameters for compiled PHP versions
    'compiled' => [
        'php_fpm_log_file_pattern'          => 'psw%PHP_VERSION%-fpm.log',
        'php_fpm_logrotate_file_pattern'    => 'psw%PHP_VERSION%-fpm',
        'php_fpm_pid_file_pattern'          => 'psw%PHP_VERSION%-fpm.pid',
        'php_fpm_reopenlogs_script_pattern' => 'psw%PHP_VERSION%-fpm-reopenlogs',
        'php_fpm_systemd_unit_pattern'      => 'psw%PHP_VERSION%-fpm.service',
        'php_fpm_sysvinit_pattern'          => 'psw%PHP_VERSION%-fpm',
        'php_fpm_tmpfile_pattern'           => 'psw%PHP_VERSION%-fpm.conf',
        'php_fpm_service_name_pattern'      => 'psw%PHP_VERSION%-fpm',
        'php_fpm_uds_path_pattern'          => 'psw%PHP_VERSION%-fpm-%DOMAIN%.sock',
        'php_fpm_run_dir'                   => '/run/phpswitcher',
        'php_fpm_log_dir'                   => '/var/log/phpswitcher',
        'php_fpm_lib_dir'                   => '/usr/local/lib/phpswitcher',
        'sys_logrotate_dir'                 => '/etc/logrotate.d',
        'sys_tmpfiles_dir'                  => '/etc/tmpfiles.d',
        'sys_systemd_unit_dir'              => '/etc/systemd/system',
        'sys_sysvinit_dir'                  => '/etc/init.d'
    ],

    // Parameters for packaged PHP versions
    'packaged' => [
        'php_fpm_service_name_pattern' => 'php%PHP_VERSION%-fpm',
        'php_fpm_uds_path_pattern'     => 'php%PHP_VERSION%-fpm-%DOMAIN%.sock',
        'php_fpm_run_dir'              => '/run/php',
        'php_fpm_log_dir'              => '/var/log/php'
    ],

    // Database parameters
    'database' => [
        'php_version_table'        => 'php_switcher_version',
        'domain_php_version_table' => 'php_switcher_version_admin'
    ]
];
