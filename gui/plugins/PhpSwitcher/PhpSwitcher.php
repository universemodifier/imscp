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
 * Class iMSCP_Plugin_PhpSwitcher
 */
class iMSCP_Plugin_PhpSwitcher extends iMSCP_Plugin_Action
{
    /**
     * @inheritDoc
     */
    public function init()
    {
        l10n_addTranslations(__DIR__ . '/l10n/mo', 'Gettext', $this->getName());
    }

    /**
     * @inheritDoc
     */
    public function register(iMSCP_Events_Manager_Interface $events)
    {
        $events->registerListener(
            [
                iMSCP_Events::onBeforeInstallPlugin,
                iMSCP_Events::onBeforeUpdatePlugin,
                iMSCP_Events::onBeforeEnablePlugin
            ],
            function (iMSCP_Events_Event $event) {
                $this->checkRequirements($event);
            }
        );
        $events->registerListener(
            [
                iMSCP_Events::onAdminScriptStart,
                iMSCP_Events::onClientScriptStart
            ],
            function (iMSCP_Events_Event $event) {
                $this->setupNavigation($event);
            }
        );
        $events->registerListener(
            [
                iMSCP_Events::onAfterDeleteDomainAlias,
                iMSCP_Events::onAfterDeleteSubdomain
            ],
            function (iMSCP_Events_Event $event) {
                $this->afterDeleteDomain($event);
            }
        );
    }

    /**
     * @inheritDoc
     */
    public function install(iMSCP_Plugin_Manager $pluginManager)
    {
        try {
            $this->migrateDb('up');
        } catch (Exception $e) {
            throw new iMSCP_Plugin_Exception(
                $e->getMessage(), $e->getCode(), $e
            );
        }
    }

    /**
     * @inheritDoc
     */
    public function update(
        iMSCP_Plugin_Manager $pluginManager, $fromVersion, $toVersion
    )
    {
        try {
            if (version_compare(
                $pluginManager->pluginGetApiVersion(), '1.5.1', '<'
            )) {
                // Force loading of new configuration parameters. This is needed
                // due to a bug in i-MSCP core. New plugin configuration
                // parameters SHOULD be available as soon as the plugin data
                // were updated.
                $this->loadConfig();
            }

            $this->clearTranslations();
            $this->migrateDb('up');
        } catch (Exception $e) {
            throw new iMSCP_Plugin_Exception(
                $e->getMessage(), $e->getCode(), $e
            );
        }
    }

    /**
     * @inheritDoc
     */
    public function uninstall(iMSCP_Plugin_Manager $pluginManager)
    {
        try {
            $this->clearTranslations();
            $this->migrateDb('down');
        } catch (Exception $e) {
            throw new iMSCP_Plugin_Exception(
                $e->getMessage(), $e->getCode(), $e
            );
        }
    }

    /**
     * @inheritDoc
     */
    public function getRoutes()
    {
        $routes = [
            '/admin/phpswitcher'  => __DIR__ . '/frontend/admin/phpswitcher.php',
            '/client/phpswitcher' => __DIR__ . '/frontend/client/phpswitcher.php',
        ];

        if (iMSCP_Registry::get('config')['HTTPD_SERVER'] == 'apache_fcgid') {
            $routes['/shared/phpswitcher'] = __DIR__
                . '/frontend/shared/phpinfo-static.php';
        }

        return $routes;
    }

    /**
     * Check requirements
     *
     * @param iMSCP_Events_Event $event
     * @return void
     */
    private function checkRequirements(iMSCP_Events_Event $event)
    {
        if ($event->getParam('pluginName') != $this->getName()) {
            return;
        }

        if (iMSCP_Registry::get('config')['DISTRO_CODENAME'] == 'trusty') {
            set_page_message(tr(
                "Ubuntu Trusty Thar (14.04) isn't supported by the PhpSwitcher plugin."
            ), 'error');

            $event->stopPropagation();
            return;
        }

        if (!in_array(
            iMSCP_Registry::get('config')['HTTPD_SERVER'],
            ['apache_fcgid', 'apache_php_fpm'])
        ) {
            set_page_message(tr(
                'The PhpSwitcher plugin requires the Fcgid or the PHP-FPM Apache2 httpd server.'
            ), 'error');

            $event->stopPropagation();
        }
    }

    /**
     * Setup plugin navigation
     *
     * @param iMSCP_Events_Event $event
     * @return void
     */
    private function setupNavigation(iMSCP_Events_Event $event)
    {
        if (is_xhr() || !iMSCP_Registry::isRegistered('navigation')) {
            return;
        }

        /** @var Zend_Navigation $navigation */
        $navigation = iMSCP_Registry::get('navigation');

        switch ($event->getName()) {
            case 'onAdminScriptStart':
                if ($page = $navigation->findOneBy(
                    'uri', '/admin/settings.php'
                )) {
                    $page->addPage([
                        'label'       => tr('PHP Switcher'),
                        'uri'         => '/admin/phpswitcher',
                        'title_class' => 'settings',
                        'order'       => 8
                    ]);
                }

                break;
            case 'onClientScriptStart':
                if ($page = $navigation->findOneBy(
                    'uri', '/client/domains_manage.php'
                )) {
                    $page->addPage([
                        'label'              => tr('PHP Switcher'),
                        'uri'                => '/client/phpswitcher',
                        'title_class'        => 'domains',
                        'privilege_callback' => [
                            'name'  => 'customerHasFeature',
                            'param' => 'php'
                        ]
                    ]);
                }
        }
    }

    /**
     * Listener for deleting entries that belong to domains being deleted
     *
     * @param iMSCP_Events_Event $event
     * @return void
     */
    private function afterDeleteDomain(iMSCP_Events_Event $event)
    {
        $domainType = $event->getParam('type', 'als');

        $table = $this->getConfigParam('database')['domain_php_version_table'];

        if ($domainType == 'sub' || $domainType == 'alssub') {
            exec_query(
                "
                    DELETE FROM `$table`
                    WHERE `domain_id` = ?
                    AND `domain_type` = ?
                ",
                [$event->getParam('subdomainId'), $domainType]
            );
            return;
        }

        exec_query(
            "
                DELETE FROM `t1` USING `$table` AS `t1`
                WHERE `t1`.`domain_id` IN(
                    SELECT `subdomain_alias_id`
                    FROM `subdomain_alias`
                    WHERE `alias_id` = ?
                )
                AND `t1`.`domain_type` = 'subals'
            ",
            [$event->getParam('domainAliasId')]
        );

        exec_query(
            "
                DELETE FROM `$table`
                WHERE `domain_id` = ?
                AND `domain_type` = 'als'
            ",
            [$event->getParam('domainAliasId')]);
    }

    /**
     * Clear translations if any
     *
     * @return void
     */
    private function clearTranslations()
    {
        /** @var Zend_Translate $translator */
        $translator = iMSCP_Registry::get('translator');
        if ($translator->hasCache()) {
            $translator->clearCache($this->getName());
        }
    }
}
