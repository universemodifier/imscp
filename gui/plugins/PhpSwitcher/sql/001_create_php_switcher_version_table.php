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
    ->getConfigParam('database')['php_version_table'];

return [
    'up'   => "
        create table if not exists `$table` (
            `version_id` int(10) unsigned auto_increment not null,
            `version_name` varchar(50) not null,
            `version_binary_path` varchar(255) not null,
            `version_confdir_path` varchar(255) not null,
            `version_status` varchar(15) not null default 'ok',
            primary key `version_id` (`version_id`),
            unique index `version_name` (`version_name`),
            index `version_status` (`version_status`)
        ) engine=InnoDB default charset=utf8 collate=utf8_unicode_ci auto_increment=1;
    ",
    'down' => "
        drop table if exists `$table`;
    "
];
