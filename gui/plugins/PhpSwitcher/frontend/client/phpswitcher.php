<?php
/**
 * i-MSCP PhpSwitcher plugin
 *
 * @author        Laurent Declercq <l.declercq@nuxwin.com>
 * @copyright (C) 2014-2019 Laurent Declercq <l.declercq@nuxwin.com>
 * @license       i-MSCP License <https://www.i-mscp.net/license-agreement.html>
 */

/**
 * @noinspection PhpUnhandledExceptionInspection PhpDocMissingThrowsInspection
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
 * Get domain data
 *
 * @return array
 */
function psw_data()
{
    global $configLevel;

    $table = iMSCP_Registry::get('pluginManager')
        ->pluginGet('PhpSwitcher')
        ->getConfigParam('database')['domain_php_version_table'];
    
    // Per user means only main domain
    $query = "
        SELECT `t1`.`domain_id`, `t1`.`domain_name`, `t1`.`domain_status`,
            IFNULL(`version_id`, 0) AS `version_id`, 'dmn' AS `domain_type`
        FROM domain AS `t1`
        LEFT JOIN `$table` AS t2 ON(
            `t2`.`domain_id` = `t1`.`domain_id` AND `t2`.`domain_type` = 'dmn'
        )
        WHERE `t1`.`domain_admin_id` = :admin_id
        AND `t1`.`domain_status` <> 'todelete'
    ";

    # Per domain or per site means also domain aliases
    if ($configLevel == 'per_domain' || $configLevel == 'per_site') {
        $query .= "
            UNION ALL
            SELECT `t1`.`alias_id` AS `domain_id`,
                `t1`.`alias_name` AS `domain_name`,
                `t1`.`alias_status` AS `domain_status`,
                IFNULL(`t3`.`version_id`, 0) AS `version_id`,
                'als' AS `domain_type`
            FROM `domain_aliasses` AS `t1`
            JOIN `domain` AS t2 ON(`t2`.`domain_id` = `t1`.`domain_id`)
            LEFT JOIN `$table` AS t3 ON(
                `t3`.`domain_id` = `t1`.`alias_id` AND `t3`.`domain_type` = 'als'
            )
            WHERE `t2`.`domain_admin_id` = :admin_id
            AND `t1`.`url_forward` = 'no'
            AND `t1`.`alias_status` NOT IN ('ordered', 'todelete')
        ";
    }

    # Per site means also subdomains
    if ($configLevel == 'per_site') {
        $query .= "
            UNION ALL
            SELECT `t1`.`subdomain_id` AS `domain_id`, CONCAT(
                `t1`.`subdomain_name`, '.', `t2`.`domain_name`
            ) AS `domain_name`, `t1`.`subdomain_status` AS `domain_status`,
            IFNULL(`t3`.`version_id`, 0) AS `version_id`, 'sub' AS `domain_type`
            FROM `subdomain` AS `t1`
            JOIN `domain` AS `t2` ON(`t2`.`domain_id` = `t1`.`domain_id`)
            LEFT JOIN `$table` AS `t3` ON(
                `t3`.`domain_id` = `t1`.`subdomain_id` AND
                `t3`.`domain_type` = 'sub'
            )
            WHERE `t2`.`domain_admin_id`  = :admin_id
            AND `t1`.`subdomain_url_forward` = 'no'
            AND `t1`.`subdomain_status` <> 'todelete'
            UNION ALL
            SELECT `t1`.`subdomain_alias_id` AS `domain_id`,
                CONCAT(
                    `t1`.`subdomain_alias_name`, '.', `t2`.`alias_name`
                ) AS `domain_name`,
                `t1`.`subdomain_alias_status` AS `domain_status`,
                IFNULL(`t4`.`version_id`, 0) AS `version_id`,
                'subals' AS `domain_type`
            FROM `subdomain_alias` AS `t1`
            JOIN `domain_aliasses` AS `t2` ON(`t2`.`alias_id` = `t1`.`alias_id`)
            JOIN `domain` AS `t3` ON(`t3`.`domain_id` = `t2`.`domain_id`)
            LEFT JOIN `$table` AS `t4` ON(
                `t4`.`domain_id` = `t1`.`subdomain_alias_id`
                AND `t4`.`domain_type` = 'subals'
            )
            WHERE `t3`.`domain_admin_id` = :admin_id
            AND `t1`.`subdomain_alias_url_forward` = 'no'
            AND `t1`.`subdomain_alias_status` <> 'todelete'
        ";
    }

    return exec_query($query, ['admin_id' => $_SESSION['user_id']])->fetchAll();
}

/**
 * Set PHP version
 *
 * @return void
 */
function psw_change()
{
    try {
        if (!isset($_POST['version_id'])
            || !isset($_POST['domain_id'])
            || !isset($_POST['domain_name'])
            || !isset($_POST['domain_type'])
        ) {
            throw new InvalidArgumentException(tr('Bad request.'), 400);
        }

        $versionId = intval($_POST['version_id']);
        $adminId = intval($_SESSION['user_id']);
        $domainName = clean_input($_POST['domain_name']);
        $domainType = clean_input($_POST['domain_type']);

        global $configLevel;

        if (($configLevel == 'per_user' && $domainType != 'dmn')
            || (
                $configLevel == 'per_domain'
                && !in_array($domainType, ['dmn', 'als'])
            )
        ) {
            throw new InvalidArgumentException(tr('Bad request.'), 400);
        }

        $table = iMSCP_Registry::get('pluginManager')
            ->pluginGet('PhpSwitcher')
            ->getConfigParam('database')['php_version_table'];
        
        iMSCP_Database::getInstance()->beginTransaction();

        $stmt = exec_query(
            "
                SELECT `version_is_default`
                FROM `$table`
                WHERE `version_id` = ?
                AND `version_status` = 'ok'
            ",
            [$versionId]
        );

        if ($stmt->rowCount() < 1) {
            throw new InvalidArgumentException(tr('Bad request.'), 400);
        }
        
        $isDefaultPhpVersion = (bool)$stmt->fetchRow(PDO::FETCH_COLUMN);

        if ($configLevel == 'per_user') {
            $domainId = get_user_domain_id($adminId);

            exec_query(
                "
                    UPDATE `domain_aliasses`
                    SET `alias_status` = 'tochange'
                    WHERE `domain_id` = ?
                    AND `alias_status` <> 'todelete'
                ",
                [$domainId]
            );
            exec_query(
                "
                    UPDATE `domain`
                    SET `domain_status` = 'tochange'
                    WHERE `domain_id` = ?
                ",
                [$domainId]
            );
        } else {
            $domainId = clean_input($_POST['domain_id']);

            switch ($domainType) {
                case 'dmn':
                    $query = "
                        UPDATE `domain`
                        SET `domain_status` = 'tochange'
                        WHERE `domain_id` = ?
                        AND `domain_admin_id` = ?
                    ";
                    break;
                case 'sub':
                    $query = "
                        UPDATE `subdomain`
                        JOIN `domain` USING(`domain_id`)
                        SET `subdomain_status` = 'tochange'
                        WHERE `subdomain_id` = ?
                        AND `domain_admin_id` = ?
                    ";
                    break;
                case 'als';
                    $query = "
                        UPDATE `domain_aliasses`
                        JOIN `domain` USING(`domain_id`)
                        SET `alias_status` = 'tochange'
                        WHERE `alias_id` = ?
                        AND `domain_admin_id` = ?
                    ";
                    break;
                case 'subals':
                    $query = "
                        UPDATE `subdomain_alias`
                        JOIN `domain_aliasses` USING(`alias_id`)
                        JOIN `domain` USING(`domain_id`)
                        SET `subdomain_alias_status` = 'tochange'
                        WHERE `subdomain_alias_id` = ?
                        AND `domain_admin_id` = ?
                    ";
                    break;
                default:
                    psw_sendJsonResponse(400, ['message' => tr('Bad request.')]);
                    return;
            }

            $stmt = exec_query($query, [$domainId, $adminId]);

            if ($stmt->rowCount() < 1) {
                throw new InvalidArgumentException(tr('Bad request.'), 400);
            }
        }

        $table = iMSCP_Registry::get('pluginManager')
            ->pluginGet('PhpSwitcher')
            ->getConfigParam('database')['domain_php_version_table'];
        
        if ($isDefaultPhpVersion) {
            exec_query(
                "
                    DELETE FROM `$table`
                    WHERE `admin_id` = ?
                    AND `domain_id` = ?
                    AND `domain_type` = ?
                ",
                [$adminId, $domainId, $domainType]
            );
        } else {
            exec_query(
                "
                    INSERT INTO `$table` (
                        `version_id`, `admin_id`, `domain_id`, `domain_name`,
                        `domain_type`
                    ) VALUES (
                        ?, ?, ?, ?, ?
                    ) ON DUPLICATE KEY UPDATE
                        `version_id` = ?
                ",
                [$versionId, $adminId, $domainId, $domainName, $domainType, $versionId]
            );
        }

        write_log(sprintf(
            '%s changed PHP version for one of his domains.',
            decode_idna($_SESSION['user_logged'])
        ), E_USER_NOTICE);

        iMSCP_Database::getInstance()->commit();
        send_request();
        set_page_message(tr(
            'PHP version will be updated. Please be patient.'
        ), 'success');
        psw_sendJsonResponse(200);
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
 * Generate page
 *
 * @param iMSCP_pTemplate $tpl
 * @return void
 */
function psw_page(iMSCP_pTemplate $tpl)
{
    $table = iMSCP_Registry::get('pluginManager')
        ->pluginGet('PhpSwitcher')
        ->getConfigParam('database')['php_version_table'];
    
    $stmt = execute_query(
        "
            SELECT `version_name`, `version_version`, `version_id`,
                `version_is_default`
            FROM `$table`
            WHERE `version_status` = 'ok'
        "
    );
    if ($stmt->rowCount() < 1) {
        throw new RuntimeException("Couldn't find PHP versions.");
    }

    $phpVersions = $stmt->fetchAll(PDO::FETCH_UNIQUE);
    ksort($phpVersions, SORT_NATURAL);

    $defaultPhpVersion = array_filter($phpVersions, function ($version) {
        return $version['version_is_default'];
    });

    if (empty($defaultPhpVersion)) {
        throw new RuntimeException("Couldn't find default PHP version.");
    }

    $defaultPhpVersionId = current($defaultPhpVersion)['version_id'];
    $domains = psw_data();

    foreach ($domains as $domain) {
        $tpl->assign([
            'DOMAIN_NAME_UNICODE'    => tohtml(decode_idna(
                $domain['domain_name']
            )),
            'DOMAIN_ID'              => tohtml($domain['domain_id'], 'htmlAttr'
            ),
            'DOMAIN_NAME'            => tohtml(
                $domain['domain_name'], 'htmlAttr'
            ),
            'DOMAIN_TYPE'            => tohtml(
                $domain['domain_type'], 'htmlAttr'
            ),
            'DOMAIN_STATUS'          => tohtml(translate_dmn_status(
                $domain['domain_status']
            )),
            'PHP_VERSION_DISABLED'   => ($domain['domain_status'] != 'ok')
                ? ' disabled' : '',
            'CURRENT_PHP_VERSION_ID' => $domain['version_id'] == 0
                ? $defaultPhpVersionId : $domain['version_id']
        ]);

        foreach ($phpVersions as $phpVersion) {
            $tpl->assign([
                'PHP_VERSION_ID'       => tohtml(
                    $phpVersion['version_id'], 'htmlAttr'
                ),
                'PHP_VERSION'          => tohtml(
                    'PHP ' . $phpVersion['version_version']
                ),
                'PHP_VERSION_SELECTED' => ($domain['version_id'] == 0 
                    && $phpVersion['version_id'] == $defaultPhpVersionId
                )
                    ? ' selected'
                    : ($phpVersion['version_id'] == $domain['version_id']
                        ? ' selected' : ''
                    )
            ]);
            $tpl->parse('PHP_VERSION_OPTION', '.php_version_option');
        }

        $tpl->parse('DOMAIN_PHP_VERSION', '.domain_php_version');
        $tpl->assign('PHP_VERSION_OPTION', '');
    }

    if ($phpinfo = iMSCP_Registry::get('pluginManager')
        ->pluginGet('PhpSwitcher')
        ->getConfigParam('phpinfo', false)
    ) {
        foreach ($phpVersions as $phpVersion) {
            $tpl->assign([
                'PHP_VERSION_ID' => tohtml(
                    $phpVersion['version_id'], 'htmlAttr'
                ),
                'PHP_VERSION'    => tohtml(
                    'PHP ' . $phpVersion['version_version']
                )
            ]);
            $tpl->parse('PHP_INFO_OPTION', '.php_info_option');
        }
    }
}

check_login('user');
iMSCP_Events_Aggregator::getInstance()->dispatch(
    iMSCP_Events::onClientScriptStart
);
customerHasFeature('php') or showNotFoundErrorPage();

$configLevel = (new iMSCP_Config_Handler_File(
    iMSCP_Registry::get('config')['CONF_DIR'] . '/php/php.data'
))['PHP_CONFIG_LEVEL'];

if (is_xhr()) {
    try {
        psw_change();
    } catch (Exception $e) {
        psw_sendJsonResponse($e->getCode(), ['message' => tr(
            $e->getMessage()
        )]);
    }
}

/** @var iMSCP_Plugin_PhpSwitcher $plugin */
$plugin = iMSCP_Registry::get('pluginManager')->pluginGet('PhpSwitcher');

$tpl = new iMSCP_pTemplate();
$tpl->define_dynamic([
    'layout'             => 'shared/layouts/ui.tpl',
    'page'               => '../../plugins/PhpSwitcher/themes/default/view/client/page.phtml',
    'page_message'       => 'layout',
    'thead_domain_name'  => 'page',
    'domain_php_version' => 'page',
    'tbody_domain_name'  => 'domain_php_version',
    'php_version_option' => 'page',
    'php_info_option'    => 'page'
]);

if ($configLevel == 'per_user') {
    $tpl->assign([
        'THEAD_DOMAIN_NAME' => '',
        'TBODY_DOMAIN_NAME' => '',
    ]);
}

if (!$plugin->getConfigParam('phpinfo', true)) {
    $tpl->assign([
        'PHPINFO_JS'   => '',
        'PHPINFO_BODY' => ''
    ]);
}

$tpl->assign([
    'TR_PAGE_TITLE' => tohtml(tr('Client / Domains / PHP Switcher')),
    'TR_HINT'       => ($configLevel == 'per_user'
            ? tohtml(tr(
                'Through this interface, you can change the PHP version for all your domains.'
            ))
            : ($configLevel == 'per_domain'
                ? tohtml(tr(
                    'Through this interface, you can change the PHP version for each of your domains, including subdomains.'
                ))
                : tohtml(tr('Through this interface, you can change the PHP version for each of your domains.'))
            )) . ' ' . tohtml(tr('Note that forwarded domains are ignored.')),
]);

generateNavigation($tpl);
generatePageMessage($tpl);
psw_page($tpl);

$tpl->parse('LAYOUT_CONTENT', 'page');
iMSCP_Events_Aggregator::getInstance()->dispatch(
    iMSCP_Events::onClientScriptEnd, ['templateEngine' => $tpl]
);
$tpl->prnt();
