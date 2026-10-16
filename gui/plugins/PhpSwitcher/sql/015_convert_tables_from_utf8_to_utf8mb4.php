<?php
/**
 * i-MSCP PhpSwitcher plugin
 *
 * @author        Laurent Declercq <l.declercq@nuxwin.com>
 * @copyright (C) 2014-2019 Laurent Declercq <l.declercq@nuxwin.com>
 * @license       i-MSCP License <https://www.i-mscp.net/license-agreement.html>
 */

/** @noinspection PhpUnhandledExceptionInspection */

$table1 = iMSCP_Registry::get('pluginManager')
    ->pluginGet('PhpSwitcher')
    ->getConfigParam('database')['php_version_table'];

$table2 = iMSCP_Registry::get('pluginManager')
    ->pluginGet('PhpSwitcher')
    ->getConfigParam('database')['domain_php_version_table'];

return [
    'up' => "
        alter table `$table1`
        drop index `version_status`,
        convert to character set utf8mb4 collate utf8mb4_unicode_ci,
        add index `version_status`(`version_status`(191));
 
        alter table `$table2`
        drop index `version_admin_domain_name`,
        add unique index `version_admin_domain_name` (`domain_name`(191)),
        drop index `version_admin_domain`,
        add index `version_admin_domain` (
            `domain_id`,`domain_name`(191),`domain_type`
        ),
        convert to character set utf8mb4 collate utf8mb4_unicode_ci;
    "
];
