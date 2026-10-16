<?php
/**
 * i-MSCP PhpSwitcher plugin
 *
 * @author        Laurent Declercq <l.declercq@nuxwin.com>
 * @copyright (C) 2014-2019 Laurent Declercq <l.declercq@nuxwin.com>
 * @license       i-MSCP License <https://www.i-mscp.net/license-agreement.html>
 */

/**
 * @noinspection PhpUnhandledExceptionInspection PhpIncludeInspection
 */

check_login('all');
iMSCP_Events_Aggregator::getInstance()->dispatch(
    iMSCP_Events::onClientScriptStart
);

isset($_GET['version_id']) or showBadRequestErrorPage();

$versionId = intval($_GET['version_id']);

/** @var iMSCP_Plugin_Manager $pluginManager */
$pluginManager = iMSCP_Registry::get('pluginManager');
$phpinfoFile = $pluginManager->pluginGetDirectory()
. "/PhpSwitcher/phpinfo/$versionId.html";

is_readable($phpinfoFile) or showNotFoundErrorPage();

include $phpinfoFile;
