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
      ALTER TABLE `letsencrypt` ADD COLUMN `admin_id` INT(10) DEFAULT NULL AFTER `letsencrypt_id`;

      -- Fills the admin_id column
      UPDATE letsencrypt AS t1
        LEFT JOIN domain AS t2 ON(t2.domain_name = t1.domain_name)
        LEFT JOIN (
          SELECT domain_admin_id, alias_name
          FROM domain_aliasses
          INNER JOIN domain USING(domain_id) 
        ) AS t3 ON(t3.alias_name = t1.domain_name)
        LEFT JOIN (
          SELECT domain_admin_id, CONCAT(subdomain_name, '.', domain_name) AS subdomain_name
          FROM subdomain
          INNER JOIN domain USING(domain_id)
        ) AS t4 ON(t4.subdomain_name = t1.domain_name)
        LEFT JOIN(
          SELECT domain_admin_id, CONCAT(subdomain_alias_name, '.', alias_name) AS subdomain_alias_name
          FROM subdomain_alias
          INNER JOIN domain_aliasses USING(alias_id) 
          INNER JOIN domain USING(domain_id)
        ) AS t5 on(t5.subdomain_alias_name = t1.domain_name)
        SET t1.admin_id = IF(ISNULL(t2.domain_name), IF(ISNULL(t3.alias_name), IF(ISNULL(t4.subdomain_name), t5.domain_admin_id, t4.domain_admin_id), t3.domain_admin_id), t2.domain_admin_id);

        -- Only for safety reasons
        DELETE FROM letsencrypt WHERE admin_id IS NULL;
    "
];
