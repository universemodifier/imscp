<?php
/**
 * i-MSCP LetsEncrypt plugin
 *
 * @author        Laurent Declercq <l.declercq@nuxwin.com>
 * @copyright (C) 2016-2018 Laurent Declercq <l.declercq@nuxwin.com>
 * @license       i-MSCP License <http://www.i-mscp.net/license-agreement.html>
 */

return [
    'up' => "
      ALTER TABLE `letsencrypt` ADD `letsencrypt_sans` TEXT CHARACTER SET utf8 COLLATE utf8_unicode_ci NOT NULL AFTER `letsencrypt_inc_www_cname`;
      UPDATE `letsencrypt` SET `letsencrypt_sans` = CONCAT(`domain_name`, IF(`letsencrypt_inc_www_cname`, CONCAT('\nwww', '.', `domain_name`), ''))
    "
];
