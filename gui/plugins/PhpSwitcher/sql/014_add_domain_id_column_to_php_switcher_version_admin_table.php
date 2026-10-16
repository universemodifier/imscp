<?php
/**
 * i-MSCP PhpSwitcher plugin
 *
 * @author        Laurent Declercq <l.declercq@nuxwin.com>
 * @copyright (C) 2014-2019 Laurent Declercq <l.declercq@nuxwin.com>
 * @license       i-MSCP License <https://www.i-mscp.net/license-agreement.html>
 */

/** @noinspection PhpUnhandledExceptionInspection */

$table = iMSCP_Registry::get('pluginManager')
    ->pluginGet('PhpSwitcher')
    ->getConfigParam('database')['domain_php_version_table'];

return [
    'up' => "
        alter table `$table`
        drop index `version_admin_domain_name_domain_type`,
        add `domain_id` int(10) unsigned not null after `admin_id`,
        add unique index `version_admin_domain` (
            `domain_id`,`domain_name`,`domain_type`
        );
          
        update `$table` as `t1`
        join `domain` AS `t2` using(`domain_name`)
        set `t1`.`domain_id` = `t2`.`domain_id`
        where `t1`.`domain_type` = 'dmn';
        
        update `$table` as `t1`
        join `domain_aliasses` AS `t2` on(
            `t2`.`alias_name` = `t1`.`domain_name`
        )
        set `t1`.`domain_id` = `t2`.`alias_id`
        where `t1`.`domain_type` = 'als';
        
        update `$table` as `t1`
        join `subdomain` AS `t2`
        join `domain` AS `t3` ON(`t3`.`domain_id` = `t2`.`domain_id`)
        set `t1`.`domain_id` = `t2`.`subdomain_id`
        where `t1`.`domain_name` = concat(
            `t2`.`subdomain_name`,'.',`t3`.`domain_name`
        )
        and `t1`.`domain_type` = 'sub';

        update `$table` as `t1`
        join `subdomain_alias` AS `t2`
        join `domain_aliasses` AS `t3` using(`alias_id`)
        set `t1`.`domain_id` = `t2`.`subdomain_alias_id`
        where `t1`.`domain_name` = concat(
            `t2`.`subdomain_alias_name`,'.',`t3`.`alias_name`
        )
        and `t1`.`domain_type` = 'subals';
    "
];
