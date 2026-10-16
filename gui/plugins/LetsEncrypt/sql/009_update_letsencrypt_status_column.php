<?php
/**
 * i-MSCP LetsEncrypt plugin
 *
 * @author        Laurent Declercq <l.declercq@nuxwin.com>
 * @copyright (C) 2016-2018 Laurent Declercq <l.declercq@nuxwin.com>
 * @license       i-MSCP License <http://www.i-mscp.net/license-agreement.html>
 */

return [
    'up' => "ALTER TABLE `letsencrypt` CHANGE `letsencrypt_status` `letsencrypt_status` TEXT CHARACTER SET utf8 COLLATE utf8_unicode_ci NOT NULL"
];
