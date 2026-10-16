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
    ->getConfigParam('database')['domain_php_version_table'];

$table2 = iMSCP_Registry::get('pluginManager')
    ->pluginGet('PhpSwitcher')
    ->getConfigParam('database')['php_version_table'];

return [
    'up'   => "
        create table if not exists `$table1` (
            `version_admin_id` int(10) unsigned auto_increment not null,
            `version_id` int(10) unsigned not null,
            `admin_id` int(10) unsigned not null,
            primary key `version_admin_id` (`version_admin_id`),
            unique index `admin_id_version_admin` (`admin_id`),
            constraint `version_admin_version_id` foreign key (`version_id`)
                references `$table2` (`version_id`) on delete cascade,
            constraint `version_admin_admin_id` foreign key (`admin_id`)
                references `admin` (`admin_id`) on delete cascade
        ) engine=InnoDB default charset=utf8 collate=utf8_unicode_ci auto_increment=1;
    ",
    'down' => "
        drop table if exists `$table1`;
    "
];
