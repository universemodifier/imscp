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
    'up' => "
        alter table `$table`
        drop `version_confdir_path_prev`,
        drop `version_confdir_path`;
    "
];
