<?php /** @noinspection PhpUnhandledExceptionInspection */

/**
 * i-MSCP LetsEncrypt plugin
 *
 * @author        Laurent Declercq <l.declercq@nuxwin.com>
 * @copyright (C) 2016-2018 Laurent Declercq <l.declercq@nuxwin.com>
 * @license       i-MSCP License <http://www.i-mscp.net/license-agreement.html>
 */

namespace ImscpLetsEncrypt;

use iMSCP_Database as Database;
use iMSCP_Events as Events;
use iMSCP_Events_Aggregator as EventManager;
use iMSCP_pTemplate as TemplateEngine;
use iMSCP_Registry as Registry;

/**
 * Get domain data by name
 *
 * @throws \Exception
 * @param int $domainId Domain unique identifier
 * @param string $domainType Domain type (dmn,sub,als,alssub)
 * @return null|array
 */
function letsencrypt_getDomainData($domainId, $domainType)
{
    switch ($domainType) {
        case 'dmn':
            $query = "
                SELECT domain_name, domain_status, domain_admin_id AS admin_id
                FROM domain
                WHERE domain_id = :domain_id
                AND domain_status <> :domain_status
            ";
            break;
        case 'als':
            $query = "
                SELECT t1.alias_name AS domain_name, t1.alias_status AS domain_status, t2.domain_admin_id AS admin_id
                FROM domain_aliasses AS t1
                JOIN domain AS t2 USING(domain_id)
                WHERE t1.alias_id = :domain_id
                AND t1.alias_status <> :domain_status
          ";
            break;
        case 'sub':
            $query = "
                SELECT CONCAT(t1.subdomain_name, '.', t2.domain_name) AS domain_name, t1.subdomain_status AS domain_status,
                    t2.domain_admin_id AS admin_id
                FROM subdomain AS t1
                JOIN domain AS t2 USING(domain_id)
                WHERE t1.subdomain_id = :domain_id
                AND t1.subdomain_status <> :domain_status
            ";
            break;
        default:
            $query = "
                SELECT CONCAT(t1.subdomain_alias_name, '.', t2.alias_name) AS domain_name, t1.subdomain_alias_status AS domain_status,
                    t3.domain_admin_id AS admin_id
                FROM subdomain_alias AS t1
                JOIN domain_aliasses AS t2 USING(alias_id)
                JOIN domain AS t3 USING(domain_id)
                WHERE t1.subdomain_alias_id = :domain_id
                AND t1.subdomain_alias_status <> :domain_status
            ";
    }

    $stmt = exec_query($query, ['domain_id' => $domainId, 'domain_status' => 'todelete']);
    return $stmt->rowCount() ? $stmt->fetchRow() : NULL;
}

/**
 * Get domains data
 *
 * @throws \Exception
 * @return \iMSCP_Database_ResultSet
 */
function letsencrypt_getDomainsData()
{
    // Main domain
    $query = <<<'QUERY'
SELECT t1.domain_id, t1.domain_name, t1.domain_status, t2.letsencrypt_id, t2.letsencrypt_sans, t2.letsencrypt_status, t2.letsencrypt_previous_status,
    t2.letsencrypt_expires, 'dmn' AS domain_type
FROM domain AS t1
LEFT JOIN letsencrypt AS t2 ON(t2.domain_name = t1.domain_name AND t2.domain_type NOT IN('control_panel', 'services'))
WHERE t1.domain_admin_id = :admin_id
AND t1.domain_status <> :domain_status
UNION ALL
SELECT t1.alias_id AS domain_id, t1.alias_name AS domain_name, t1.alias_status AS domain_status, letsencrypt_id, t3.letsencrypt_sans,
    t3.letsencrypt_status, t3.letsencrypt_previous_status, t3.letsencrypt_expires, 'als' AS domain_type
FROM domain_aliasses AS t1
JOIN domain AS t2 USING(domain_id)
LEFT JOIN letsencrypt AS t3 ON(t3.admin_id = t2.domain_admin_id AND t3.domain_name = t1.alias_name)
WHERE t2.domain_admin_id = :admin_id AND t1.alias_status <> :domain_status
UNION ALL
SELECT t1.subdomain_id AS domain_id, CONCAT(t1.subdomain_name, '.', t2.domain_name) AS domain_name, t1.subdomain_status AS domain_status,
    t3.letsencrypt_id, t3.letsencrypt_sans, t3.letsencrypt_status, t3.letsencrypt_previous_status, t3.letsencrypt_expires, 'sub' AS domain_type
FROM subdomain AS t1
JOIN domain AS t2 USING(domain_id)
LEFT JOIN letsencrypt AS t3 ON(t3.admin_id = t2.domain_admin_id AND t3.domain_name = CONCAT(t1.subdomain_name, '.', t2.domain_name))
WHERE t2.domain_admin_id  = :admin_id
AND t1.subdomain_status <> :domain_status
UNION ALL
SELECT t1.subdomain_alias_id AS domain_id, CONCAT(t1.subdomain_alias_name, '.', t2.alias_name) AS domain_name,
    t1.subdomain_alias_status AS domain_status, t4.letsencrypt_id, t4.letsencrypt_sans, t4.letsencrypt_status, t4.letsencrypt_previous_status,
    t4.letsencrypt_expires, 'alssub' AS domain_type
FROM subdomain_alias AS t1
JOIN domain_aliasses t2 USING(alias_id) 
JOIN domain AS t3 USING(domain_id)
LEFT JOIN letsencrypt AS t4 ON(t4.admin_id = t3.domain_admin_id AND t4.domain_name = CONCAT(t1.subdomain_alias_name, '.', t2.alias_name))
WHERE domain_admin_id = :admin_id AND subdomain_alias_status <> :domain_status
QUERY;

    return exec_query($query, ['admin_id' => intval($_SESSION['user_id']), 'domain_status' => 'todelete']);
}

/**
 * Handle LetsEncrypt action
 *
 * @throws \Exception
 * @return void
 */
function letsencrypt_handleActions()
{
    if (!isset($_POST['letsencrypt_action'])
        || !in_array($_POST['letsencrypt_action'], ['toadd', 'torenew', 'todelete'], true)
        || !isset($_POST['letsencrypt_domain_id'])
        || !isset($_POST['letsencrypt_domain_type'])
        || ($_POST['letsencrypt_action'] !== 'todelete' && !isset($_POST['letsencrypt_sans']))
    ) {
        $response = new JsonResponse(400, ['message' => tr('Bad request.')]);
        $response->sendResponse();
    }

    $domainId = (int)$_POST['letsencrypt_domain_id'];
    $domainType = clean_input($_POST['letsencrypt_domain_type']);

    $domainData = letsencrypt_getDomainData($domainId, $domainType);
    if (!$domainData || $domainData['admin_id'] != $_SESSION['user_id']) {
        $response = new JsonResponse(400, ['message' => tr('Bad request.')]);
        $response->sendResponse();
    }

    $dnsNames = [];

    if ($_POST['letsencrypt_action'] != 'todelete') {
        $messages = [];

        // Parse list of DNS names
        $dnsNames = array_map(function ($dnsName) {
            // We need trim again. See https://www.w3.org/MarkUp/html-spec/html-spec_8.html#SEC8.2.1
            return trim($dnsName);
        }, explode(PHP_EOL, trim(clean_input($_POST['letsencrypt_sans']))));

        // Make sure that certificate name (a.k.a common name) is listed in list of DNS names
        $dnsNames[] = $domainData['domain_name'];

        // Remove duplicate if any
        $dnsNames = array_unique($dnsNames);

        // Make sure that there are not more DNS names than max allowed
        if (sizeof($dnsNames) > 100) {
            $messages[] = tr('You cannot add more than 100 DNS names per SSL certificate.');
        }

        $cfg = Registry::get('config');

        /** @var \iMSCP_Plugin_LetsEncrypt $plugin */
        $plugin = Registry::get('pluginManager')->pluginGet('LetsEncrypt');

        // Enable DNS names strict validation if needed but not if the SSL
        // certificate name matches either the server hostname or control panel
        // hostname.
        $dnsNamesStrictValidation = !in_array($domainData['domain_name'], [$cfg['SERVER_HOSTNAME'], $cfg['BASE_SERVER_VHOST']])
            && $plugin->getConfigParam('dns_names_strict_validation', false);

        // Make sure that all DNS names are valid
        foreach ($dnsNames as &$dnsName) {
            $idnDNSname = $dnsName;
            if ((FALSE === $san = encode_idna($dnsName)) || !Utils::validateDNSname($domainData['domain_name'], $dnsName, $dnsNamesStrictValidation)) {
                $messages[] = $dnsNamesStrictValidation
                    ? tr('The %s DNS name is either invalid or not allowed.', '<strong>' . $idnDNSname . '</strong>')
                    : tr('The %s DNS name is invalid.', '<strong>' . $idnDNSname . '</strong>');
            }
        }

        if (!empty($messages)) {
            $response = new JsonResponse(422, ['message' => implode('<br>', $messages)]);
            $response->sendResponse();
        }

        natsort($dnsNames);
        $dnsNames = implode(PHP_EOL, $dnsNames);
    }

    try {
        Database::getInstance()->beginTransaction();

        $stmt = exec_query(
            'SELECT letsencrypt_id, letsencrypt_status, letsencrypt_previous_status FROM letsencrypt WHERE domain_id = ? AND domain_type = ?',
            [$domainId, $domainType]
        );

        $userLogged = Utils::getRealIdentityName();
        $idnCertName = decode_idna($domainData['domain_name']);

        if (!$stmt->rowCount()) {
            if ($_POST['letsencrypt_action'] != 'toadd') {
                $response = new JsonResponse(400, ['message' => tr('Bad request.')]);
                $response->sendResponse();
            }

            exec_query(
                "
                    INSERT INTO letsencrypt (
                        admin_id, domain_name, domain_id, domain_type, letsencrypt_sans, letsencrypt_status, letsencrypt_status_date
                    ) VALUES (
                        ?, ?, ?, ?, ?, 'toadd', UNIX_TIMESTAMP()
                    )
                ",
                [$domainData['admin_id'], $domainData['domain_name'], $domainId, $domainType, $dnsNames]
            );
            // If $certName matches with domain name of another Let's encrypt
            // entity, we must update its list of DNS names. It will be
            // automatically processed by the backend.
            exec_query('UPDATE letsencrypt SET letsencrypt_sans = ? WHERE letsencrypt_id <> LAST_INSERT_ID() AND domain_name = ?', [
                $dnsNames, $domainData['domain_name']
            ]);
            write_log(sprintf(sprintf("The %s Let's Encrypt SSL certificate has been issued by %s", $idnCertName, $userLogged)), E_USER_NOTICE);
            set_page_message(tohtml(tr('A new SSL certificate will be issued.')), 'success');
            Database::getInstance()->commit();
            send_request();

            $response = new JsonResponse(200, ['message' => tr('success')]);
            $response->sendResponse();
        }

        $certData = $stmt->fetchRow();

        if (!Utils::validateStateTransition($certData['letsencrypt_status'], $certData['letsencrypt_previous_status'], $_POST['letsencrypt_action'])) {
            $response = new JsonResponse(400, ['message' => tr('Bad request.')]);
            $response->sendResponse();
        }

        if ($_POST['letsencrypt_action'] == 'todelete') {
            exec_query(
                "
                    UPDATE letsencrypt
                    SET letsencrypt_status = 'todelete', letsencrypt_previous_status = NULL, letsencrypt_status_date = UNIX_TIMESTAMP()
                    WHERE letsencrypt_id = ?
                ",
                [$certData['letsencrypt_id']]
            );

            if ($certData['letsencrypt_previous_status'] == 'toadd') {
                set_page_message(tohtml(tr('Issuance of the SSL certificate has been canceled.')), 'success');
                write_log(sprintf("The %s Let's Encrypt SSL certificate issuance has been scheduled for cancellation by %s", $idnCertName, $userLogged), E_USER_NOTICE);
            } else {
                set_page_message(tohtml(tr('The SSL certificate will be revoked.')), 'success');
                write_log(sprintf("The %s Let's Encrypt SSL certificate has been scheduled for revocation by %s", $idnCertName, $userLogged), E_USER_NOTICE);
            }
        } else {
            exec_query(
                "
                    UPDATE letsencrypt
                    SET letsencrypt_sans = ?, letsencrypt_status = ?, letsencrypt_previous_status = NULL, letsencrypt_status_date = UNIX_TIMESTAMP()
                    WHERE letsencrypt_id = ?
                ",
                [$dnsNames, $_POST['letsencrypt_action'], $certData['letsencrypt_id']]
            );
            // If $certName matches with domain name of another Let's encrypt
            // entity, we must update its list of DNS names. It will be
            // automatically processed by the backend.
            exec_query('UPDATE letsencrypt SET letsencrypt_sans = ? WHERE letsencrypt_id <> ? AND domain_name = ?', [
                $dnsNames, $certData['letsencrypt_id'], $domainData['domain_name']
            ]);

            if ($certData['letsencrypt_previous_status'] == 'toadd') {
                set_page_message(tohtml(tr('A new SSL certificate will be issued.')), 'success');
                write_log(sprintf("The %s Let's Encrypt SSL certificate has been scheduled for issuance by %s", $idnCertName, $userLogged), E_USER_NOTICE);
            } else {
                set_page_message(tohtml(tr('The SSL certificate will be renewed.')), 'success');
                write_log(sprintf("The %s Let's Encrypt SSL certificate has been scheduled for renewal by %s", $idnCertName, $userLogged), E_USER_NOTICE);
            }
        }

        Database::getInstance()->commit();
        send_request();

        $response = new JsonResponse(200, ['message' => tr('success')]);
        $response->sendResponse();
    } catch (\Exception $e) {
        Database::getInstance()->rollBack();
        throw $e;
    }
}

/**
 * Generate page
 *
 * TODO: Pagination
 *
 * @throws \Exception
 * @param TemplateEngine $tpl
 * @return void
 */
function generatePage($tpl)
{
    $cfg = Registry::get('config');

    /** @var \iMSCP_Plugin_LetsEncrypt $plugin */
    $plugin = Registry::get('pluginManager')->pluginGet('LetsEncrypt');
    $renewalPolicyInSeconds = $plugin->getConfigParam('renewal_policy', 2592000);
    $renewalPolicyInDays = Utils::getRenewalPolicyInDays($renewalPolicyInSeconds);

    $stmt = letsencrypt_getDomainsData();
    while ($row = $stmt->fetchRow(\PDO::FETCH_ASSOC)) {
        $tpl->assign([
            'LETSENCRYPT_CERTIFICATE_NAME' => tohtml(decode_idna($row['domain_name'])),
            'LETSENCRYPT_TARGET'           => tohtml('frm_' . $row['domain_id'] . '_' . $row['domain_type'], 'htmlAttr'),
            'LETSENCRYPT_DOMAIN_ID'        => tohtml($row['domain_id'], 'htmlAttr'),
            'LETSENCRYPT_DOMAIN_TYPE'      => tohtml($row['domain_type'], 'htmlAttr')
        ]);

        if (NULL === $row['letsencrypt_id']) {
            // Retrieve DNS names list from admin side SSL certificate if any
            // case where control panel domain or server hostname is being added as customer domain or subdomain
            $row['letsencrypt_sans'] = exec_query("SELECT letsencrypt_sans FROM letsencrypt WHERE domain_name = ?", $row['domain_name'])->fetchRow(
                \PDO::FETCH_COLUMN
            ) ?: $row['domain_name'];

            $row['letsencrypt_sans'] = explode(PHP_EOL, $row['letsencrypt_sans']);

            if (in_array($row['domain_type'], ['dmn', 'als'])) {
                $row['letsencrypt_sans'][] = "www.{$row['domain_name']}";
            }

            natsort($row['letsencrypt_sans']);
            $row['letsencrypt_sans'] = implode(PHP_EOL, array_unique($row['letsencrypt_sans']));

            $tpl->assign([
                'LETSENCRYPT_SANS'               => tohtml(trim($row['letsencrypt_sans'])),
                'LETSENCRYPT_EXPIRE_DATE'        => tohtml(tr('N/A')),
                'LETSENCRYPT_NEXT_RENEWAL_DATE'  => tohtml(tr('N/A')),
                'LETSENCRYPT_STATUS_TOOLTIP'     => '',
                'LETSENCRYPT_STATUS'             => tohtml(Utils::translateStatus('disabled')),
                'LETSENCRYPT_BUTTON1_HAS_ERROR'  => false,
                'LETSENCRYPT_BUTTON1_ACTION'     => tohtml(tr('Create')),
                'LETSENCRYPT_BUTTON1_ACTION_VAL' => 'toadd',
                'LETSENCRYPT_BUTTON1_CONFIRM'    => '',
                'LETSENCRYPT_BUTTON2'            => ''
            ]);
            $tpl->parse('LETSENCRYPT_BUTTON1', 'letsencrypt_button1');
            $tpl->parse('LETSENCRYPT_BUTTON3', 'letsencrypt_button3');
            $tpl->parse('LETSENCRYPT_ITEM', '.letsencrypt_item');
            continue;
        }

        $tpl->assign([
            'LETSENCRYPT_SANS'              => tohtml(trim($row['letsencrypt_sans'])),
            'LETSENCRYPT_EXPIRE_DATE'       => tohtml($row['letsencrypt_expires'] > 0 ? date($cfg['DATE_FORMAT'], $row['letsencrypt_expires']) : tr('N/A')),
            'LETSENCRYPT_NEXT_RENEWAL_DATE' => tohtml($row['letsencrypt_expires'] > 0 ? date($cfg['DATE_FORMAT'], $row['letsencrypt_expires'] - $renewalPolicyInSeconds) : tr('N/A')),
            'LETSENCRYPT_STATUS'            => nl2br(tohtml(Utils::translateStatus($row['letsencrypt_status'])), false)
        ]);

        switch ($row['letsencrypt_status']) {
            case 'ok': // SSL certificate renewal or revocation
                $tpl->assign([
                    'LETSENCRYPT_STATUS_TOOLTIP'     => '',
                    'LETSENCRYPT_BUTTON1_HAS_ERROR'  => false,
                    'LETSENCRYPT_BUTTON1_ACTION'     => tohtml(tr('Renew')),
                    'LETSENCRYPT_BUTTON1_ACTION_VAL' => 'torenew',
                    'LETSENCRYPT_BUTTON1_CONFIRM'    => tohtml(tr('Are you sure you want to renew this SSL certificate manually? SSL certificates are renewed automatically. Manual renewal is only needed in very few cases, such as when the automatic renewal failed for an unknown reason. Note that the renewal will be performed only if the SSL certificate is effectively due for renewal, according our renewal policy which state that an SSL certificate will be renewed %s before its expiry date.', ntr('1 day', '%d days', $renewalPolicyInDays, $renewalPolicyInDays)), 'htmlAttr'),
                    'LETSENCRYPT_BUTTON2_ACTION'     => tohtml(tr('Revoke')),
                    'LETSENCRYPT_BUTTON2_ACTION_VAL' => 'todelete',
                    'LETSENCRYPT_BUTTON2_CONFIRM'    => tohtml(tr("Are you sure you want to revoke this SSL certificate? Bear in mind that revoking an SSL certificate doesn't reset the Let's Encrypt rate limits."), 'htmlAttr'),
                ]);
                $tpl->parse('LETSENCRYPT_BUTTON1', 'letsencrypt_button1');
                $tpl->parse('LETSENCRYPT_BUTTON2', 'letsencrypt_button2');
                $tpl->parse('LETSENCRYPT_BUTTON3', 'letsencrypt_button3');
                break;
            case 'toadd': // SSL certificate being issued
            case 'torenew': // SSL certificate being renewed
            case 'todelete': // SSL certificate being revoked
                $tpl->assign([
                    'LETSENCRYPT_STATUS_TOOLTIP' => '',
                    'LETSENCRYPT_BUTTON1'        => '',
                    'LETSENCRYPT_BUTTON2'        => '',
                    'LETSENCRYPT_BUTTON3'        => ''
                ]);
                break;
            case 'pending': // SSL certificate in pending state
            default: // SSL certificate in error state
                // SSL certificate is in pending state or error state, meaning
                // that an action such as 'toadd', 'torenew', 'todelete' has
                // been postponed or aborted due to a Let's Encrypt rate limit
                // hit or another problem (technical problem, validation
                // failure, service outage...) In such case, only a new attempt
                // or cancellation is allowed, except for the 'todelete' action
                // that can be queued for a new attempt only.
                $tpl->assign([
                    'LETSENCRYPT_STATUS_TOOLTIP'     => $row['letsencrypt_status'] == 'pending'
                        ? sprintf('<span class="tips icon i_exclamation" id="letsencrypt_status_pending_tooltip" title="%s">&nbsp;</span>',
                            tohtml(tr("You've hit a Let's Encrypt rate limit: %s", $row['letsencrypt_previous_status'] == 'toadd'
                                ? tr('The issuance of this SSL certificate has been queued for later processing.')
                                : ($row['letsencrypt_previous_status'] == 'torenew'
                                    ? tr('The renewal of this SSL certificate has been queued for later processing.')
                                    : tr('The revocation of this SSL certificate has been queued for later processing.')
                                )
                            ))
                        )
                        : '',
                    'LETSENCRYPT_BUTTON1_HAS_ERROR'  => $row['letsencrypt_status'] != 'pending',
                    'LETSENCRYPT_BUTTON1_ACTION'     => tohtml(tr('Force retry')),
                    'LETSENCRYPT_BUTTON1_ACTION_VAL' => $row['letsencrypt_previous_status'],
                    'LETSENCRYPT_BUTTON1_CONFIRM'    => $row['letsencrypt_status'] == 'pending'
                        ? tohtml(tr("Are you sure you want to manually trigger a new attempt? A pending task generally means that you've reached a Let's Encrypt rate limit. In such a case you should best wait for the next automatic attempt."), 'htmlAttr')
                        : tohtml($row['letsencrypt_previous_status'] == 'todelete'
                            ? tr('Prior triggering a new attempt for SSL certificate revocation, make sure that the problem that led to the error is solved.')
                            : tr("Prior triggering a new attempt for SSL certificate issuance or renewal, make sure that the problem that led to the error is solved. Bear in mind that there is a Let's Encrypt limit of 5 validation failures per account, per hostname, per hour."),
                            'htmlAttr'
                        )
                ]);
                $tpl->parse('LETSENCRYPT_BUTTON1', 'letsencrypt_button1');

                if ($row['letsencrypt_previous_status'] == 'todelete') {
                    $tpl->assign([
                        'LETSENCRYPT_BUTTON2' => '',
                        'LETSENCRYPT_BUTTON3' => '',
                    ]);
                } else {
                    $tpl->assign([
                        'LETSENCRYPT_BUTTON2_ACTION'     => tohtml(tr('Cancel')),
                        'LETSENCRYPT_BUTTON2_ACTION_VAL' => 'todelete',
                        'LETSENCRYPT_BUTTON2_CONFIRM'    => $row['letsencrypt_status'] == 'pending'
                            ? tohtml(tr("Are you sure you want to cancel the pending task for this SSL certificate? The cancelation will lead to revocation and full deletion of the SSL certificate if one is existing. However, this will not prevent you to issue another one later on. The cancellation is the best option when something is going wrong and that a new attempt doesn't solve the problem."), 'htmlAttr')
                            : ($row['letsencrypt_previous_status'] == 'toadd'
                                ? tr('Are you sure you want to cancel the SSL certificate issuance?')
                                : ($row['letsencrypt_previous_status'] == 'torenew'
                                    ? tr("Are you sure you want to cancel the SSL certificate renewal? The cancelation will lead to revocation and full deletion of the SSL certificate if one is existing. However, this will not prevent you to issue another one later on. The cancellation is the best option when something is going wrong and that a new attempt doesn't solve the problem.")
                                    : ''
                                ))
                    ]);
                    $tpl->parse('LETSENCRYPT_BUTTON2', 'letsencrypt_button2');
                    $tpl->parse('LETSENCRYPT_BUTTON3', 'letsencrypt_button3');
                }
        }

        $tpl->parse('LETSENCRYPT_ITEM', '.letsencrypt_item');
    }
}

EventManager::getInstance()->dispatch(Events::onClientScriptStart);
check_login('user');

if (is_xhr()) {
    try {
        letsencrypt_handleActions();
    } catch (\Exception $e) {
        write_log(sprintf('LetsEncrypt: An unexpected error occurred: %s', $e->getMessage()), E_USER_ERROR);
        $response = new JsonResponse(500, ['message' => tr('An unexpected error occurred.')]);
        $response->sendResponse();
    }
}

$tpl = new TemplateEngine();
$tpl->define_dynamic([
    'layout'              => 'shared/layouts/ui.tpl',
    'page'                => '../../plugins/LetsEncrypt/themes/default/view/client/letsencrypt.phtml',
    'page_message'        => 'layout',
    'letsencrypt_item'    => 'page',
    'letsencrypt_button1' => 'letsencrypt_item',
    'letsencrypt_button2' => 'letsencrypt_item',
    'letsencrypt_button3' => 'letsencrypt_item'
]);
$tpl->assign('TR_PAGE_TITLE', tohtml(tr("Client / Domains / Let's Encrypt"), 'htmlAttr'));

generateNavigation($tpl);
generatePageMessage($tpl);
generatePage($tpl);

$tpl->parse('LAYOUT_CONTENT', 'page');
EventManager::getInstance()->dispatch(Events::onClientScriptEnd, ['templateEngine' => $tpl]);
$tpl->prnt();
