<?php
/**
 * i-MSCP LetsEncrypt plugin
 *
 * @author        Laurent Declercq <l.declercq@nuxwin.com>
 * @copyright (C) 2016-2018 Laurent Declercq <l.declercq@nuxwin.com>
 * @license       i-MSCP License <http://www.i-mscp.net/license-agreement.html>
 */

use iMSCP_Database as Database;
use iMSCP_Events as Events;
use iMSCP_Events_Event as Event;
use iMSCP_Events_Manager_Interface as EventManagerInterface;
use iMSCP_Plugin_Action as PluginAction;
use iMSCP_Plugin_Exception as PluginException;
use iMSCP_Plugin_Manager as PluginManager;
use iMSCP_Registry as Registry;

/**
 * Class iMSCP_Plugin_LetsEncrypt
 */
class iMSCP_Plugin_LetsEncrypt extends PluginAction
{
    /**
     * @inheritdoc
     * @throws PluginException
     */
    public function init()
    {
        try {
            /** @var Zend_Loader_StandardAutoloader $loader */
            $loader = Zend_Loader_AutoloaderFactory::getRegisteredAutoloader('Zend_Loader_StandardAutoloader');
            $loader->registerNamespace('ImscpLetsEncrypt', __DIR__ . '/frontend/library/ImscpLetsEncrypt');
            l10n_addTranslations(__DIR__ . '/l10n/mo', 'Gettext', $this->getName());
        } catch (Exception $e) {
            throw new PluginException($e->getMessage(), $e->getCode(), $e);
        }
    }

    /**
     * @inheritdoc
     * @throws PluginException
     */
    public function register(EventManagerInterface $em)
    {
        try {
            $em->registerListener([Events::onAdminScriptStart, Events::onClientScriptStart], [$this, 'setupNavigation']);
            $em->registerListener(Events::onClientScriptStart, [$this, 'overrideSSLinterface'], 999);
            $em->registerListener([Events::onAfterDeleteDomainAlias, Events::onAfterDeleteSubdomain], [$this, 'onAfterDeleteDomain']);
            $em->registerListener(Events::onAfterDeleteCustomer, [$this, 'onAfterDeleteCustomer']);
        } catch (Exception $e) {
            throw new PluginException($e->getMessage(), $e->getCode(), $e);
        }
    }

    /**
     * @inheritdoc
     * @throws PluginException
     */
    public function install(PluginManager $pm)
    {
        try {
            $this->migrateDb('up');
        } catch (Exception $e) {
            throw new PluginException($e->getMessage(), $e->getCode(), $e);
        }
    }

    /**
     * @inheritdoc
     * @throws PluginException
     */
    public function update(PluginManager $pm, $fromVersion, $toVersion)
    {
        try {
            $this->clearTranslations();
            $this->migrateDb('up');
        } catch (Exception $e) {
            throw new PluginException($e->getMessage(), $e->getCode(), $e);
        }
    }

    /**
     * @inheritdoc
     * @throws PluginException
     */
    public function uninstall(PluginManager $pm)
    {
        try {
            $this->clearTranslations();
            $this->migrateDb('down');
        } catch (Exception $e) {
            throw new PluginException($e->getMessage(), $e->getCode(), $e);
        }
    }

    /**
     * @inheritdoc
     * @throws PluginException
     */
    public function getRoutes()
    {
        try {
            $pluginDir = $this->getPluginManager()->pluginGetDirectory() . '/' . $this->getName();

            return [
                '/admin/letsencrypt'  => $pluginDir . '/frontend/admin/letsencrypt.php',
                '/client/letsencrypt' => $pluginDir . '/frontend/client/letsencrypt.php'
            ];
        } catch (Exception $e) {
            throw new PluginException($e->getMessage(), $e->getCode(), $e);
        }
    }

    /**
     * Setup plugin navigation
     *
     * @throws PluginException
     * @param Event $e
     * @return void
     */
    public function setupNavigation(Event $e)
    {
        try {
            if (!iMSCP_Registry::isRegistered('navigation') || is_xhr()) {
                return;
            }

            /** @var Zend_Navigation $nav */
            $nav = Registry::get('navigation');

            switch ($e->getName()) {
                case 'onAdminScriptStart':
                    $page = $nav->findOneBy('uri', '/admin/system_info.php');
                    $page->addPage([
                        'label'       => tr("Let's Encrypt"),
                        'uri'         => '/admin/letsencrypt',
                        'title_class' => 'letsencrypt'
                    ]);
                    break;
                case 'onClientScriptStart':
                    $page = $nav->findOneBy('uri', '/client/domains_manage.php');
                    $page->addPage([
                        'label'       => tr("Let's Encrypt"),
                        'uri'         => '/client/letsencrypt',
                        'title_class' => 'letsencrypt'
                    ]);
                    break;
                default:
                    throw new iMSCP_Plugin_Exception(('Invalid context'));
            }
        } catch (Exception $e) {
            throw new PluginException($e->getMessage(), $e->getCode(), $e);
        }
    }

    /**
     * Override SSL interface for Let's Encrypt enabled domains
     *
     * @throws PluginException
     * @return void
     */
    public function overrideSSLinterface()
    {
        try {
            if (strripos($_SERVER['SCRIPT_NAME'], '/client/cert_view.php') === false) {
                return;
            }

            if (!isset($_REQUEST['domain_id']) || !isset($_REQUEST['domain_type'])) {
                showBadRequestErrorPage();
            }

            $domainId = intval($_REQUEST['domain_id']);
            $domainType = clean_input($_REQUEST['domain_type']);

            $stmt = exec_query('SELECT letsencrypt_status FROM letsencrypt WHERE admin_id = ? AND domain_id = ? AND domain_type = ?', [
                $_SESSION['user_id'], $domainId, $domainType
            ]);
            if (!$stmt->rowCount()) {
                // Return early since the SSL certificate is not managed by this plugin.
                return;
            }

            $row = $stmt->fetchRow();

            // Short-circuit access to default SSL certificate management page if there is a task in progress for the
            // Let's Encrypt SSL certificate
            if ($row['letsencrypt_status'] != 'ok') {
                set_page_message(tr('A task for SSL certificate is in progress.'), 'warning');
                redirectTo('/client/letsencrypt');
            }

            switch ($_SERVER['REQUEST_METHOD']) {
                case 'GET':
                    // Warn user on the fact that actions are restricted when SSL certificate is managed by this plugin
                    /** @noinspection HtmlUnknownTarget */
                    set_page_message(
                        tr("This SSL certificate is managed by Let's Encrypt. Therefore, you can only change HSTS parameters. For any other action, go to the <a href=\"%s\">Let's Encrypt</a> interface.", "/client/letsencrypt"),
                        'static_warning'
                    );

                    // Override default SSL page template
                    $this->getPluginManager()->getEventManager()->registerListener(
                        Events::onParseTemplate, function ($e) {
                        /** @var iMSCP_Events_Event $e */
                        $e->getParam('templateEngine')->assign([
                            // Hide the button for selfsigned SSL certificate generation
                            'SSL_CERTIFICATE_SELFSIGNED'      => '',
                            // Hide the private key password field
                            'SSL_CERTIFICATE_PK_PWD'          => '',
                            // Override default disabled input fields (we want keep the HSTS input fields enabled)
                            'SSL_CERTIFICATE_DISABLED_FIELDS' => '$("textarea").prop("readonly", true);',
                            // Override default 'update' action button to force disabling of SSL certificate input fields
                            'SSL_CERTIFICATE_ACTION_UPDATE'   => '<input name="add_update" id="lets_encrypt_update" type="submit" value="{TR_ACTION}">',
                            // Hide the 'delete' action button
                            'SSL_CERTIFICATE_ACTION_DELETE'   => ''
                        ]);
                    });
                    break;
                case 'POST':
                    // Short-circuit delete action and give the user a reason
                    // Note: We do this even if delete button is hidden. This is a safety measure.
                    if (isset($_POST['delete'])) {
                        set_page_message(tr("You cannot delete an SSL certificate that is managed by Let's Encrypt through this page. You can only change HSTS parameters."), 'error');
                        redirectTo("/client/cert_view.php?domain_id=$domainId&domain_type=$domainType");
                    }

                    // Update HSTS parameters and schedule domain changes
                    $db = Database::getInstance();
                    try {
                        $db->beginTransaction();

                        $allowHSTS = (isset($_POST['allow_hsts']) && in_array($_POST['allow_hsts'], ['on', 'off'])) ? $_POST['allow_hsts'] : 'off';
                        $hstsMaxAge = ($allowHSTS == 'on' && isset($_POST['hsts_max_age']) && $_POST['hsts_max_age'] != ''
                            && $_POST['hsts_max_age'] >= 0) ? intval($_POST['hsts_max_age']) : '31536000';
                        $hstsIncludeSubDomains = ($allowHSTS == 'on' && isset($_POST['hsts_include_subdomains'])
                            && in_array($_POST['hsts_include_subdomains'], ['on', 'off'])) ? $_POST['hsts_include_subdomains'] : 'off';

                        exec_query(
                            '
                                UPDATE ssl_certs
                                SET allow_hsts = ?, hsts_max_age = ?, hsts_include_subdomains = ?
                                WHERE domain_id = ?
                                AND domain_type = ?
                            ',
                            [$allowHSTS, $hstsMaxAge, $hstsIncludeSubDomains, $domainId, $domainType]
                        );

                        switch ($domainType) {
                            case 'dmn':
                                $query = "UPDATE domain SET domain_status = 'tochange' WHERE domain_id = ?";
                                break;
                            case 'als':
                                $query = "UPDATE domain_aliasses SET alias_status = 'tochange' WHERE alias_id = ?";
                                break;
                            case 'sub':
                                $query = "UPDATE subdomain SET subdomain_status = 'tochange' WHERE subdomain_id = ?";
                                break;
                            default:
                                $query = "UPDATE subdomain_alias SET subdomain_alias_status = ? WHERE subdomain_alias_id = ?";
                        }

                        exec_query($query, [$domainId]);
                        $db->commit();
                        send_request();
                        set_page_message(tr('HSTS parameters successfully scheduled for update.'), 'success');
                    } catch (Exception $e) {
                        $db->rollBack();
                        write_log(sprintf("Couldn't not update HSTS parameters: %s", $e->getMessage()), E_USER_ERROR);
                        set_page_message(tr('An unexpected error occurred.'), 'error');
                    }
                    redirectTo('/client/domains_manage.php');
                    exit;
                default:
                    showBadRequestErrorPage();
            }
        } catch (Exception $e) {
            throw new PluginException($e->getMessage(), $e->getCode(), $e);
        }
    }

    /**
     * Schedule deletion of any Let's Encrypt SSL certificate that belong to the domain being deleted
     *
     * @throws iMSCP_Exception_Database
     * @throws PluginException
     * @param Event $e
     * @return void
     */
    public function onAfterDeleteDomain(Event $e)
    {
        try {
            $domainType = $e->getParam('type', 'als');

            if (in_array($domainType, ['sub', 'alssub'])) {
                exec_query("UPDATE letsencrypt SET letsencrypt_status = 'todelete' WHERE domain_id = ? AND domain_type = ?", [
                    $e->getParam('subdomainId'), $domainType
                ]);
                return;
            }

            Database::getInstance()->beginTransaction();
            exec_query("UPDATE letsencrypt SET letsencrypt_status = 'todelete' WHERE domain_id = ? AND domain_type = 'als'", [
                $e->getParam('domainAliasId')
            ]);
            exec_query(
                "
                    UPDATE letsencrypt AS t1
                    JOIN subdomain_alias AS t2 ON( t2.subdomain_alias_id = t1.domain_id)
                    SET t1.letsencrypt_status = 'todelete'
                    WHERE t1.domain_type = 'alssub'
                    AND t2.alias_id = ?
                ",
                $e->getParam('domainAliasId')
            );
            Database::getInstance()->commit();
        } catch (Exception $e) {
            Database::getInstance()->rollBack();
            throw new PluginException($e->getMessage(), $e->getCode(), $e);
        }
    }

    /**
     * Schedule deletion of any Let's Encrypt SSL certificate that belong to the customer being deleted
     *
     * @throws iMSCP_Plugin_Exception
     * @param Event $e
     * @return void
     */
    public function onAfterDeleteCustomer(Event $e)
    {
        try {
            exec_query("UPDATE letsencrypt SET letsencrypt_status = 'todelete' WHERE admin_id = ?", [$e->getParam('customerId')]);
        } catch (Exception $e) {
            throw new PluginException($e->getMessage(), $e->getCode(), $e);
        }
    }

    /**
     * @inheritdoc
     * @throws PluginException
     */
    public function getItemWithErrorStatus()
    {
        try {
            return execute_query(
                "
                    SELECT letsencrypt_id AS item_id, letsencrypt_status AS status, domain_name as item_name, 'letsencrypt' AS `table`,
                        'letsencrypt_status' AS `field`
                    FROM letsencrypt
                    WHERE letsencrypt_status NOT IN('ok', 'toadd', 'torenew', 'todelete', 'pending')
                "
            )->fetchAll();
        } catch (Exception $e) {
            throw new PluginException($e->getMessage(), $e->getCode(), $e);
        }
    }

    /**
     * @inheritdoc
     * @throws PluginException
     */
    public function changeItemStatus($table, $field, $itemId)
    {
        try {
            exec_query(
                "
                    UPDATE letsencrypt
                    SET letsencrypt_status = letsencrypt_previous_status
                    WHERE letsencrypt_id = ?
                    AND letsencrypt_previous_status IS NOT NULL
                ",
                [$itemId]
            );
        } catch (Exception $e) {
            throw new PluginException($e->getMessage(), $e->getCode(), $e);
        }
    }

    /**
     * @inheritdoc
     * @throws PluginException
     */
    public function getCountRequests()
    {
        try {
            return execute_query(
                "SELECT COUNT(*) FROM letsencrypt WHERE letsencrypt_status IN('toadd', 'torenew', 'todelete')"
            )->fetchRow(PDO::FETCH_COLUMN);
        } catch (Exception $e) {
            throw new PluginException($e->getMessage(), $e->getCode(), $e);
        }
    }

    /**
     * Clear translations if any
     *
     * @throws PluginException
     * @return void
     */
    protected function clearTranslations()
    {
        try {
            /** @var Zend_Translate $translator */
            $translator = Registry::get('translator');
            if ($translator->hasCache()) {
                $translator->clearCache($this->getName());
            }
        } catch (Exception $e) {
            throw new PluginException($e->getMessage(), $e->getCode(), $e);
        }
    }
}
