<?php
/**
 * i-MSCP PhpSwitcher plugin
 *
 * @author        Laurent Declercq <l.declercq@nuxwin.com>
 * @copyright (C) 2014-2019 Laurent Declercq <l.declercq@nuxwin.com>
 * @license       i-MSCP License <https://www.i-mscp.net/license-agreement.html>
 */

/**
 * @noinspection PhpUnhandledExceptionInspection PhpDocMissingThrowsInspection PhpUnused
 */

/**
 * Send JSON response
 *
 * @param int $statusCode HTTPD status code
 * @param array $data JSON data
 * @return void
 */
function psw_sendJsonResponse($statusCode = 200, array $data = [])
{
    header('Cache-Control: no-cache, must-revalidate');
    header('Expires: Mon, 26 Jul 1997 05:00:00 GMT');
    header('Content-type: application/json');

    switch ($statusCode) {
        case 200:
            header('Status: 200 OK');
            break;
        case 400:
            header('Status: 400 Bad Request');
            break;
        case 500:
            header('Status: 500 Internal Server Error');
            break;
        default:
            throw new LogicException('Invalid status code');
    }

    echo json_encode($data);
    exit;
}

/**
 * Get PHP version
 *
 * @return void
 */
function psw_get()
{
    try {
        if (!isset($_GET['version_id'])) {
            throw new InvalidArgumentException(tr('Bad request.'), 400);
        }

        $table = iMSCP_Registry::get('pluginManager')
            ->pluginGet('PhpSwitcher')
            ->getConfigParam('database')['php_version_table'];

        $stmt = exec_query("SELECT * FROM `$table` WHERE `version_id` = ?", [
            intval($_GET['version_id'])
        ]);

        if ($stmt->rowCount() < 1) {
            throw new InvalidArgumentException(tr('Bad request.'), 400);
        }

        psw_sendJsonResponse(200, $stmt->fetchRow());
    } catch (Exception $e) {
        throw new RuntimeException(
            tr("Couldn't process the request: %s", $e->getMessage()), 500, $e
        );
    }
}

/**
 * Add a PHP version
 *
 * @eturn void
 */
function psw_add()
{
    try {
        if (!isset($_POST['version_pear_directory_path'])
            || !isset($_POST['version_cgi_binary_path'])
            || !isset($_POST['version_fpm_binary_path'])
            || !isset($_POST['version_fpm_config_file_path'])
            || !isset($_POST['version_fpm_pool_directory_path'])
        ) {
            throw new InvalidArgumentException(tr('Bad request.'), 400);
        }

        $pearDirPath = clean_input($_POST['version_pear_directory_path']);
        $cgiBinaryPath = clean_input($_POST['version_cgi_binary_path']);
        $fpmBinaryPath = clean_input($_POST['version_fpm_binary_path']);
        $fpmConfigFilePath = clean_input($_POST['version_fpm_config_file_path']);
        $fpmPoolDirPath = clean_input($_POST['version_fpm_pool_directory_path']);

        foreach (
            [
                $pearDirPath, $cgiBinaryPath, $fpmBinaryPath, $fpmConfigFilePath,
                $fpmPoolDirPath
            ] as $value
        ) {
            if ($value == '') {
                throw new InvalidArgumentException(
                    tr('All settings are required.'), 400
                );
            }
        }

        $table = iMSCP_Registry::get('pluginManager')
            ->pluginGet('PhpSwitcher')
            ->getConfigParam('database')['php_version_table'];

        iMSCP_Database::getInstance()->beginTransaction();

        exec_query(
            "
                INSERT INTO `$table` (
                    `version_version`,
                    `version_pear_directory_path`,
                    `version_cgi_binary_path`,
                    `version_fpm_binary_path`,
                    `version_fpm_config_file_path`,
                    `version_fpm_pool_directory_path`,
                    `version_status`
                ) VALUES (
                    null, ?, ?, ?, ?, ?, 'toadd'
                )
            ",
            [
                utils_normalizePath($pearDirPath),
                utils_normalizePath($cgiBinaryPath),
                utils_normalizePath($fpmBinaryPath),
                utils_normalizePath($fpmConfigFilePath),
                utils_normalizePath($fpmPoolDirPath)
            ]
        );

        write_log(sprintf('PHP version has been added.'), E_USER_NOTICE);
        iMSCP_Database::getInstance()->commit();
        send_request();
        psw_sendJsonResponse(200, ['message' => tr(
            'PHP version will be added.'
        )]);
    } catch (Exception $e) {
        if (iMSCP_Database::getInstance()->inTransaction()) {
            iMSCP_Database::getInstance()->rollBack();
        }

        if ($e instanceof iMSCP_Exception_Database) {
            if ($e->getCode() == 23000) {
                throw new InvalidArgumentException(tr(
                    "One or more of given paths are already set for another PHP version. You cannot register multiple PHP versions with the same paths, except for the PEAR directory path."
                ), 400, $e);
            }
        }

        throw new RuntimeException(
            tr("Couldn't process the request: %s", $e->getMessage()), 500, $e
        );
    }
}

/**
 * Edit a PHP version
 *
 * @return void
 */
function psw_edit()
{
    try {
        if (!isset($_POST['version_id'])
            || !isset($_POST['version_pear_directory_path'])
            || !isset($_POST['version_cgi_binary_path'])
            || !isset($_POST['version_fpm_binary_path'])
            || !isset($_POST['version_fpm_config_file_path'])
            || !isset($_POST['version_fpm_pool_directory_path'])
        ) {
            throw new InvalidArgumentException(tr('Bad request.'), 400);
        }

        $versionId = intval($_POST['version_id']);
        $pearDirPath = clean_input($_POST['version_pear_directory_path']);
        $cgiBinaryPath = clean_input($_POST['version_cgi_binary_path']);
        $fpmBinaryPath = clean_input($_POST['version_fpm_binary_path']);
        $fpmConfigFilePath = clean_input($_POST['version_fpm_config_file_path']);
        $fpmPoolDirPath = clean_input($_POST['version_fpm_pool_directory_path']);

        foreach (
            [
                $pearDirPath, $cgiBinaryPath, $fpmBinaryPath, $fpmConfigFilePath,
                $fpmPoolDirPath
            ] as $value
        ) {
            if ($value == '') {
                throw new InvalidArgumentException(
                    tr('All settings are required.'), 400
                );
            }
        }

        $table = iMSCP_Registry::get('pluginManager')
            ->pluginGet('PhpSwitcher')
            ->getConfigParam('database')['php_version_table'];

        $stmt = exec_query(
            "
                SELECT `version_status`
                FROM `$table`
                WHERE `version_id` = ?
                AND `version_is_default` <> 1
            ",
            [$versionId]
        );
        
        if($stmt->rowCount() < 1) {
            throw new InvalidArgumentException(tr('Bad request.'), 400);
        }
        
        $versionStatus = $stmt->fetchRow(PDO::FETCH_COLUMN);

        iMSCP_Database::getInstance()->beginTransaction();

        if(in_array(
            $versionStatus,
            ['toadd', 'tochange', 'todisable', 'toenable', 'todelete', 'phpinfo'],
            true
        )) {
            throw new InvalidArgumentException(tr('Bad request.'), 400);
        }

        exec_query(
            "
                UPDATE `$table`
                    SET `version_version` = null,
                    `version_pear_directory_path`  = ?,
                    `version_cgi_binary_path` = ?,
                    `version_fpm_binary_path` = ?,
                    `version_fpm_config_file_path` = ?,
                    `version_fpm_pool_directory_path` = ?,
                    `version_is_packaged` = null,
                    `version_status` = IF(
                        `version_status` <> 'disabled', 'tochange', 'disabled'
                    ) 
                WHERE `version_id` = ?
            ",
            [
                utils_normalizePath($pearDirPath),
                utils_normalizePath($cgiBinaryPath),
                utils_normalizePath($fpmBinaryPath),
                utils_normalizePath($fpmConfigFilePath),
                utils_normalizePath($fpmPoolDirPath),
                $versionId
            ]
        );

        write_log(sprintf('PHP version has been updated.'), E_USER_NOTICE);
        iMSCP_Database::getInstance()->commit();
        
        if($versionStatus == 'ok') {
            send_request();
            psw_sendJsonResponse(200, ['message' => tr(
                'PHP version will be updated.'
            )]);
        } else {
            psw_sendJsonResponse(200, ['message' => tr(
                "PHP version has been updated but changes won't be taken into consideration till its reactivation."
            )]);
        }
    } catch (Exception $e) {
        if (iMSCP_Database::getInstance()->inTransaction()) {
            iMSCP_Database::getInstance()->rollBack();
        }

        if ($e instanceof iMSCP_Exception_Database && $e->getCode() == 23000) {
            throw new InvalidArgumentException(tr(
                "One or more of given paths are already set for another PHP version. You cannot register multiple PHP versions with the same paths, except for the PEAR directory path."
            ), 400, $e);
        }

        throw new RuntimeException(
            tr("Couldn't process the request: %s", $e->getMessage()), 500, $e
        );
    }
}

/**
 * Activate a PHP version
 *
 * @return void
 */
function psw_enable()
{
    try {
        if (!isset($_POST['version_id'])) {
            throw new InvalidArgumentException(tr('Bad request.'), 400);
        }

        $table = iMSCP_Registry::get('pluginManager')
            ->pluginGet('PhpSwitcher')
            ->getConfigParam('database')['php_version_table'];

        iMSCP_Database::getInstance()->beginTransaction();

        $stmt = exec_query(
            "
                UPDATE `$table`
                SET `version_status` = 'toenable'
                WHERE `version_id` = ?
                AND `version_status` = 'disabled'
            ",
            [intval($_POST['version_id'])]
        );

        if ($stmt->rowCount() < 1) {
            throw new InvalidArgumentException(tr('Bad request.'), 400);
        }

        write_log(sprintf('PHP version has been activated.'), E_USER_NOTICE);
        iMSCP_Database::getInstance()->commit();
        send_request();
        psw_sendJsonResponse(200, [
            'message' => tr('PHP version will be activated.')
        ]);
    } catch (Exception $e) {
        if (iMSCP_Database::getInstance()->inTransaction()) {
            iMSCP_Database::getInstance()->rollBack();
        }

        throw new RuntimeException(
            tr("Couldn't process the request: %s", $e->getMessage()), 500, $e
        );
    }
}

/**
 * Deactivate a PHP version
 *
 * @return void
 */
function psw_disable()
{
    try {
        if (!isset($_POST['version_id'])) {
            throw new InvalidArgumentException(tr('Bad request.'), 400);
        }

        $table = iMSCP_Registry::get('pluginManager')
            ->pluginGet('PhpSwitcher')
            ->getConfigParam('database')['php_version_table'];

        iMSCP_Database::getInstance()->beginTransaction();

        $stmt = exec_query(
            "
                UPDATE `$table`
                SET `version_status` = 'todisable'
                WHERE `version_id` = ?
                AND `version_status` = 'ok'
            ",
            [intval($_POST['version_id'])]
        );

        if ($stmt->rowCount() < 1) {
            throw new InvalidArgumentException(tr('Bad request.'), 400);
        }

        write_log(sprintf('PHP version has been deactivated.'), E_USER_NOTICE);
        iMSCP_Database::getInstance()->commit();
        send_request();
        psw_sendJsonResponse(200, [
            'message' => tr('PHP version will be deactivated.')
        ]);
    } catch (iMSCP_Exception_Database $e) {
        if (iMSCP_Database::getInstance()->inTransaction()) {
            iMSCP_Database::getInstance()->rollBack();
        }

        throw new RuntimeException(
            tr("Couldn't process the request: %s", $e->getMessage()), 500, $e
        );
    }
}

/**
 * Delete a PHP version
 *
 * @return void
 */
function psw_delete()
{
    try {
        if (!isset($_POST['version_id'])) {
            throw new InvalidArgumentException(tr('Bad request.'), 400);
        }

        $table = iMSCP_Registry::get('pluginManager')
            ->pluginGet('PhpSwitcher')
            ->getConfigParam('database')['php_version_table'];

        iMSCP_Database::getInstance()->beginTransaction();

        $stmt = exec_query(
            "
                UPDATE `$table`
                SET `version_status` = 'todelete'
                WHERE `version_id` = ?
            ",
            [intval($_POST['version_id'])]
        );

        if ($stmt->rowCount() < 1) {
            throw new InvalidArgumentException(tr('Bad request.'), 400);
        }

        write_log('PHP version has been deleted.', E_USER_NOTICE);
        iMSCP_Database::getInstance()->commit();
        send_request();
        psw_sendJsonResponse(200, [
            'message' => tr('PHP version will be deleted.')
        ]);
    } catch (Exception $e) {
        if (iMSCP_Database::getInstance()->inTransaction()) {
            iMSCP_Database::getInstance()->rollBack();
        }

        throw new RuntimeException(
            tr("Couldn't process the request: %s", $e->getMessage()), 500, $e
        );
    }
}

/**
 * PHP info
 *
 * @return void
 */
function psw_phpinfo()
{
    try {
        if (!isset($_POST['version_id']) ||
            iMSCP_Registry::get('config')['HTTPD_SERVER'] != 'apache_fcgid'
            || !iMSCP_Registry::get('pluginManager')
                ->pluginGet('PhpSwitcher')
                ->getConfigParam('phpinfo', false)
        ) {
            throw new InvalidArgumentException(tr('Bad request.'), 400);
        }

        $versionId = intval($_POST['version_id']);

        $table = iMSCP_Registry::get('pluginManager')
            ->pluginGet('PhpSwitcher')
            ->getConfigParam('database')['php_version_table'];

        iMSCP_Database::getInstance()->beginTransaction();

        $stmt = exec_query(
            "
                UPDATE `$table`
                SET `version_status` = 'phpinfo'
                WHERE `version_status` = 'ok'
                AND `version_id` = ?
            ",
            [$versionId]
        );

        if ($stmt->rowCount() < 1) {
            throw new InvalidArgumentException(tr('Bad request.'), 400);
        }

        write_log(
            sprintf(
                'Static PHP info file for PHP version with ID %d has been regenerated.',
                $versionId
            ),
            E_USER_NOTICE
        );
        iMSCP_Database::getInstance()->commit();
        send_request();
        psw_sendJsonResponse(200, [
            'message' => tr('Static PHP info file will be regenerated.')
        ]);
    } catch (Exception $e) {
        if (iMSCP_Database::getInstance()->inTransaction()) {
            iMSCP_Database::getInstance()->rollBack();
        }

        throw new RuntimeException(
            tr("Couldn't process the request: %s", $e->getMessage()), 500, $e
        );
    }
}

/**
 * Get table data
 *
 * @return void
 */
function psw_table()
{
    try {
        $table = iMSCP_Registry::get('pluginManager')
            ->pluginGet('PhpSwitcher')
            ->getConfigParam('database')['php_version_table'];

        $columns = [
            'version_id', 'version_version', 'version_name',
            'version_cgi_binary_path', 'version_fpm_binary_path',
            'version_is_packaged', 'version_is_default', 'version_status'
        ];
        $nbColumns = count($columns);
        $indexColumn = 'version_id';

        /* Paging */
        $limit = '';
        if (isset($_GET['iDisplayStart']) && $_GET['iDisplayLength'] != '-1') {
            $limit = 'LIMIT ' . intval($_GET['iDisplayStart']) . ', '
                . intval($_GET['iDisplayLength']);
        }

        /* Ordering */
        $order = '';
        if (isset($_GET['iSortCol_0'])) {
            $order = 'ORDER BY ';
            for ($i = 0; $i < intval($_GET['iSortingCols']); $i++) {
                if ($_GET['bSortable_' . intval($_GET['iSortCol_' . $i])] == 'true'
                ) {
                    $order .= $columns[intval($_GET['iSortCol_' . $i])] . ' '
                        . $_GET['sSortDir_' . $i] . ', ';
                }
            }

            $order = substr_replace($order, '', -2);
            if ($order == 'ORDER BY') {
                $order = '';
            }
        }

        /* Filtering */
        $where = '';
        if ($_GET['sSearch'] != '') {
            $where .= 'WHERE (';
            for ($i = 0; $i < $nbColumns; $i++) {
                $where .= $columns[$i] . ' LIKE '
                    . quoteValue("%{$_GET['sSearch']}%") . ' OR ';
            }
            $where = substr_replace($where, '', -3);
            $where .= ')';
        }

        /* Individual column filtering */
        for ($i = 0; $i < $nbColumns; $i++) {
            if (isset($_GET["bSearchable_$i"])
                && $_GET["bSearchable_$i"] == 'true'
                && $_GET["sSearch_$i"] != ''
            ) {
                $where .= "AND {$columns[$i]} LIKE "
                    . quoteValue("%{$_GET["sSearch_$i"]}%");
            }
        }

        /* Get data to display */
        $rResult = execute_query(
            'SELECT SQL_CALC_FOUND_ROWS '
            . str_replace(' , ', ' ', implode(', ', $columns))
            . " FROM $table $where $order $limit"
        );

        /* Data set length after filtering */
        $filteredTotal = execute_query('SELECT FOUND_ROWS()')
            ->fetchRow(PDO::FETCH_COLUMN);

        /* Total data set length */
        $total = execute_query("SELECT COUNT($indexColumn) FROM $table")
            ->fetchRow(PDO::FETCH_COLUMN);

        /* Output */
        $output = [
            'sEcho'                => intval($_GET['sEcho']),
            'iTotalRecords'        => $total,
            'iTotalDisplayRecords' => $filteredTotal,
            'aaData'               => []
        ];

        /** @var iMSCP_Plugin_PhpSwitcher $plugin */
        $plugin = iMSCP_Registry::get('pluginManager')
            ->pluginGet('PhpSwitcher');
        $phpinfo = iMSCP_Registry::get('config')['HTTPD_SERVER']
            == 'apache_fcgid' && $plugin->getConfigParam('phpinfo', false);

        $trEnableTooltip = tohtml(tr('Activate this PHP version'), 'htmlAttr');
        $trDisableTooltip = tohtml(tr('Deactivate this PHP version'), 'htmlAttr');
        $trEditTooltip = tohtml(tr('Edit this PHP version'), 'htmlAttr');
        $trDeleteTooltip = tohtml(tr('Delete this PHP version'), 'htmlAttr');
        $trPhpInfoTooltip = tohtml(tr(
            'Regenerate static PHP info file for this PHP version'
        ), 'htmlAttr');

        while ($data = $rResult->fetchRow()) {
            $row = [];
            for ($i = 0; $i < $nbColumns; $i++) {
                if ($columns[$i] == 'version_is_default') {
                    continue;
                }

                if ($columns[$i] == 'version_version'
                    && NULL !== $data[$columns[$i]]
                ) {
                    $row[$columns[$i]] = $data[$columns[$i]]
                        . ($data['version_is_default']
                            ? ' (' . tr('default') . ')' : ''
                        );
                } elseif ($columns[$i] == 'version_status') {
                    if ($data[$columns[$i]] == 'phpinfo') {
                        $row[$columns[$i]] = tr(
                            'Regeneration of static PHP info file in progress...'
                        );
                    } else {
                        $row[$columns[$i]] = translate_dmn_status(
                            $data[$columns[$i]], true
                        );
                    }
                } elseif ($columns[$i] == 'version_is_packaged') {
                    $row[$columns[$i]] = tohtml($data[$columns[$i]]
                        ? tr('Packaged') : 'Compiled');
                } elseif ($columns[$i] == 'version_name') {
                    $row[$columns[$i]] = $data[$columns[$i]] === NULL
                        ? ''
                        : tohtml(str_replace(
                            '%PHP_VERSION%',
                            $data[$columns[$i]],
                            $data['version_is_packaged']
                                ? $plugin->getConfigParam('packaged')['php_fpm_service_name_pattern']
                                : $plugin->getConfigParam('compiled')['php_fpm_service_name_pattern']
                        ));
                } else {
                    $row[$columns[$i]] = tohtml($data[$columns[$i]]
                        ?: tr('n/a'));
                }
            }

            $versionId = tohtml($data['version_id'], 'htmlAttr');
            $version = tohtml($data['version_version']
                ?: tr('unknown'), 'htmlAttr');

            if ($data['version_is_default']) {
                switch ($data['version_status']) {
                    case 'ok':
                        if ($phpinfo) {
                            $row['version_actions'] .=
                                "<span title=\"$trPhpInfoTooltip\""
                                . " data-action=\"phpinfo\""
                                . " data-version-id=\"$versionId\""
                                . " data-version-version=\"$version\""
                                . " class=\"icon i_reload clickable\">&nbsp;</span>";
                        } else {
                            $row['version_actions'] = tr('n/a');
                        }

                        break;
                    default:
                        $row['version_actions'] = tr('n/a');
                }
            } else {
                switch ($data['version_status']) {
                    case 'ok':
                        $row['version_actions'] = "<span title=\"$trEditTooltip\""
                            . " data-action=\"edit\" data-version-id=\"$versionId\""
                            . " class=\"icon i_edit clickable\">&nbsp;</span>"

                            . "<span title=\"$trDisableTooltip\""
                            . " data-action=\"disable\""
                            . " data-version-id=\"$versionId\""
                            . " data-version-version=\"$version\""
                            . " class=\"icon i_disabled clickable\">&nbsp;</span>"

                            . "<span title=\"$trDeleteTooltip\""
                            . " data-action=\"delete\""
                            . " data-version-id=\"$versionId\""
                            . " data-version-version=\"$version\""
                            . " class=\"icon i_close clickable\">&nbsp;</span>";

                        if ($phpinfo) {
                            $row['version_actions'] .=
                                "<span title=\"$trPhpInfoTooltip\""
                                . " data-action=\"phpinfo\""
                                . " data-version-id=\"$versionId\""
                                . " data-version-version=\"$version\""
                                . " class=\"icon i_reload clickable\">&nbsp;</span>";
                        }

                        break;
                    case 'disabled':
                        $row['version_actions'] = "<span title=\"$trEditTooltip\""
                            . " data-action=\"edit\" data-version-id=\"$versionId\""
                            . " class=\"icon i_edit clickable\">&nbsp;</span>"

                            . "<span title=\"$trEnableTooltip\""
                            . " data-action=\"enable\""
                            . " data-version-id=\"$versionId\""
                            . " data-version-version=\"$version\""
                            . " class=\"icon i_open clickable\">&nbsp;</span>"

                            . "<span title=\"$trDeleteTooltip\""
                            . " data-action=\"delete\""
                            . " data-version-id=\"$versionId\""
                            . " data-version-version=\"$version\""
                            . " class=\"icon i_close clickable\">&nbsp;</span>";
                        break;
                    default:
                        if (!in_array(
                            $data['version_status'],
                            [
                                'toadd', 'tochange', 'toenable', 'todisable',
                                'todelete', 'phpinfo'
                            ]
                        )) {
                            $row['version_actions'] =
                                "<span title=\"$trEditTooltip\""
                                . " data-action=\"edit\""
                                . " data-version-id=\"$versionId\""
                                . " class=\"icon i_edit clickable\">&nbsp;</span>"

                                . "<span title=\"$trDeleteTooltip\""
                                . " data-action=\"delete\""
                                . " data-version-id=\"$versionId\""
                                . " data-version-version=\"$version\""
                                . " class=\"icon i_close clickable\">&nbsp;</span>";
                        } else {
                            $row['version_actions'] = tr('n/a');
                        }
                }
            }

            $output['aaData'][] = $row;
        }

        psw_sendJsonResponse(200, $output);
    } catch (Exception $e) {
        throw new RuntimeException(
            tr("Couldn't process the request: %s", $e->getMessage()), 500, $e
        );
    }
}

function psw_page(iMSCP_pTemplate $tpl)
{
    $table = iMSCP_Registry::get('pluginManager')
        ->pluginGet('PhpSwitcher')
        ->getConfigParam('database')['php_version_table'];

    $stmt = execute_query(
        "
            SELECT `version_version`
            FROM `$table`
            WHERE `version_is_default` = 1
            LIMIT 1
        "
    );
    if ($stmt->rowCount() < 1) {
        throw new RuntimeException("Couldn't find default PHP version.");
    }

    $tpl->assign('DEFAULT_PHP_VERSION', tojs($stmt->fetchRow(PDO::FETCH_COLUMN)));
}

function psw_select()
{
    $table = iMSCP_Registry::get('pluginManager')
        ->pluginGet('PhpSwitcher')
        ->getConfigParam('database')['php_version_table'];

    $stmt = execute_query(
        "
            SELECT `version_version`, `version_id`, `version_is_default`
            FROM `$table`
            WHERE `version_status` = 'ok'
        "
    );
    if ($stmt->rowCount() < 1) {
        echo "<select name=\"php_info_select\" id=\"php_info_select\"></select>";
        exit;
    }

    $phpVersions = $stmt->fetchAll(PDO::FETCH_UNIQUE);
    ksort($phpVersions);
    
    $defaultTr = tohtml(tr("Select a version to view its configuration"));
    
    $tpl = new iMSCP_pTemplate();
    $tpl->define_no_file_dynamic('tpl', <<<"EOF"
<select name="php_info_select" id="php_info_select" style="vertical-align: baseline;">
    <option value="unselectable" style="display:none" disabled selected>$defaultTr</option>
    <!-- BDP: php_info_option -->
    <option value="{PHP_VERSION_ID}">{PHP_VERSION}</option>
    <!-- EDP: php_info_option -->
</select>
EOF
);
    $tpl->define_dynamic('php_info_option', 'tpl');

    foreach ($phpVersions as $phpVersionName => $phpVersion) {
        $tpl->assign([
            'PHP_VERSION_ID' => tohtml($phpVersion['version_id'], 'htmlAttr'),
            'PHP_VERSION'    => tohtml('PHP ' . $phpVersionName)
        ]);
        $tpl->parse('PHP_INFO_OPTION', '.php_info_option');
    }
    
    $tpl->parse('TPL', 'tpl');
    $tpl->prnt();
    exit;
}

check_login('admin');
iMSCP_Events_Aggregator::getInstance()->dispatch(
    iMSCP_Events::onAdminScriptStart
);

if (isset($_REQUEST['action'])) {
    if (is_xhr()) {
        try {
            $action = clean_input($_REQUEST['action']);

            if (!in_array($action, [
                'table', 'get', 'select', 'add', 'edit', 'enable', 'disable',
                'delete', 'phpinfo'
            ], true)) {
                throw new InvalidArgumentException(tr('Bad request.'), 400);
            }

            call_user_func('psw_' . $action);
        } catch (Exception $e) {
            psw_sendJsonResponse(500, ['message' => tr(
                $e->getMessage()
            )]);
        }
    }

    showBadRequestErrorPage();
}

$tpl = new iMSCP_pTemplate();
$tpl->define_dynamic([
    'layout'          => 'shared/layouts/ui.tpl',
    'page'            => '../../plugins/PhpSwitcher/themes/default/view/admin/page.phtml',
    'page_message'    => 'layout'
]);
$tpl->assign('TR_PAGE_TITLE', tohtml(tr('Admin / Settings / PHP Switcher')));

generateNavigation($tpl);
generatePageMessage($tpl);
psw_page($tpl);

$tpl->parse('LAYOUT_CONTENT', 'page');
iMSCP_Events_Aggregator::getInstance()->dispatch(
    iMSCP_Events::onAdminScriptEnd, ['templateEngine' => $tpl]
);
$tpl->prnt();
