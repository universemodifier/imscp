<?php
/**
 * i-MSCP LetsEncrypt plugin
 *
 * @author        Laurent Declercq <l.declercq@nuxwin.com>
 * @copyright (C) 2016-2018 Laurent Declercq <l.declercq@nuxwin.com>
 * @license       i-MSCP License <http://www.i-mscp.net/license-agreement.html>
 */

return [
    'up'   => "
        CREATE TABLE IF NOT EXISTS letsencrypt (
            letsencrypt_id int(10) unsigned AUTO_INCREMENT NOT NULL,
            domain_name varchar(255) COLLATE utf8_unicode_ci NOT NULL,
            letsencrypt_status varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT 'ok',
            letsencrypt_previous_status varchar(255) COLLATE utf8_unicode_ci DEFAULT NULL,
            letsencrypt_status_date int(10) unsigned NOT NULL DEFAULT '0',
            letsencrypt_expires int(10) unsigned NOT NULL DEFAULT '0',
            PRIMARY KEY letsencrypt_id (letsencrypt_id),
            UNIQUE KEY domain_name (domain_name),
            KEY letsencrypt_status (letsencrypt_status)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci AUTO_INCREMENT=1;
    ",
    'down' => 'DROP TABLE IF EXISTS letsencrypt'
];
