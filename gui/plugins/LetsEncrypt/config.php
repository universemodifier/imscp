<?php
/**
 * i-MSCP LetsEncrypt plugin
 *
 * @author        Laurent Declercq <l.declercq@nuxwin.com>
 * @copyright (C) 2016-2018 Laurent Declercq <l.declercq@nuxwin.com>
 * @license       i-MSCP License <http://www.i-mscp.net/license-agreement.html>
 */

return [
    // Path to Certbot client (default: /usr/bin/certbot)
    //
    // Debian provides this binary. certbot-auto is not used.
    'certbot_path'                => '/usr/bin/certbot',

    // Certbot client version to use (default: released)
    //
    // Allow to force usage of latest development version of the Certbot client.
    //
    // Available options:
    //  - released : Usage of the latest released version (recommended)
    //  - develop  : Usage of the development version from github repository
    //
    // Plugin backward compatibility is not guaranteed for the development
    // version of the Certbot client. 
    'certbot_version'             => 'released',

    // Additional command line options passed-in to Certbot client while
    // issuing or renewing an SSL certificate
    //
    // Bear in mind that this plugin make use of the 'certonly' Certbot client
    // command and the 'webroot' authenticator plugin.
    //
    // See https://certbot.eff.org/docs/using.html for more details about
    // available command line options.
    //
    // Please, make one option (and one option value if any) per array value.
    // For instance:
    //
    //  'certbot_create_options' => [
    //      '--rsa-key-size 4096',
    //      '--staging'
    //  ]
    'certbot_create_options'      => [
    ],

    // Additional command line options passed-in to the Certbot client while
    // revoking an SSL certificate
    //
    // See https://certbot.eff.org/docs/using.html for more details about
    // available command line options.
    //
    // Please, make one option (and one option value if any) per array value.
    // For instance:
    //
    //  'certbot_revoke_options' => array(
    //      '--staging'
    //  )
    'certbot_revoke_options'      => [
    ],

    // Let's Encrypt storage path (default: /etc/letsencrypt)
    'letsencrypt_storage_path'    => '/etc/letsencrypt',

    // Cronjob for renewal of SSL certificates (default: once per day).
    'cronjob_renew'               => [
        'minute' => '@daily',
        'hour'   => '',
        'day'    => '',
        'month'  => '',
        'dweek'  => ''
    ],

    // Cronjob for pending tasks of SSL certificates (default: once per hour)
    'cronjob_pending'             => [
        'minute' => '@hourly',
        'hour'   => '',
        'day'    => '',
        'month'  => '',
        'dweek'  => ''
    ],

    // Minimum waiting time for new attempt of pending tasks (default: 1 hour).
    'pending_policy'              => 3600,

    // How many days before its expiry date an SSL certificate must be renewed (default: 21 days)
    //
    // Accepted value: Number of days in second in range 86400..7776000.
    // A Reasonable value is between 10 and 30 days.
    'renewal_policy'              => 1814400,

    // Strict validation for SSL certificate DNS names (SANs) (default: false)
    // A strict validation mean that a DNS name for an SSL certificate will be
    // allowed only if it is part of the domain for which the SSL certificate
    // is or has been issued. This check is only for customers SSL certificates
    // and only if the certificate name doesn't matches with either the server
    // hostname or control panel hostname
    'dns_names_strict_validation' => false
];
