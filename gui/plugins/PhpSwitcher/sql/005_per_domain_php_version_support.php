<?php
/**
 * i-MSCP PhpSwitcher plugin
 *
 * @author        Laurent Declercq <l.declercq@nuxwin.com>
 * @copyright (C) 2014-2019 Laurent Declercq <l.declercq@nuxwin.com>
 * @license       i-MSCP License <https://www.i-mscp.net/license-agreement.html>
 */

/** @noinspection PhpUnhandledExceptionInspection */

$table = iMSCP_Registry::get('pluginManager')
    ->pluginGet('PhpSwitcher')
    ->getConfigParam('database')['domain_php_version_table'];

return [
    'up' => "
        alter table `$table`
        add `domain_name` varchar(255) not null,
        add domain_type enum('dmn','sub','als','subals') not null;

        update `$table` AS `t1`
        join `domain` AS `t2`
        set `t1`.`domain_name` = `t2`.`domain_name`, `t1`.`domain_type` = 'dmn'
        where `t1`.`admin_id` = `t2`.`domain_admin_id`;

        alter table `$table`
        drop index `admin_id_version_admin`,
        add index `version_admin_admin_id` (`admin_id`),
        add unique index `version_admin_domain_name` (`domain_name`),
        add index `version_admin_domain_name_domain_type` (
            `domain_name`,`domain_type`
        );
    "
];
