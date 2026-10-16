<?php
/**
 * i-MSCP LetsEncrypt plugin
 *
 * @author        Laurent Declercq <l.declercq@nuxwin.com>
 * @copyright (C) 2016-2018 Laurent Declercq <l.declercq@nuxwin.com>
 * @license       i-MSCP License <http://www.i-mscp.net/license-agreement.html>
 */

namespace ImscpLetsEncrypt;

use DateInterval;
use DateTime;

/**
 * Class Utils
 * @package ImscpLetsEncrypt
 */
final class Utils
{
    /**
     * Returns translated let's encrypt item status
     *
     * @param string $status Item status to translate
     * @return string Translated status
     * @throws \Zend_Exception
     */
    static function translateStatus($status)
    {
        switch ($status) {
            case 'ok':
                return tr('Activated');
            case 'toadd':
                return tr('New SSL certificate issuance in progress...');
            case 'torenew':
                return tr('SSL certificate renewal in progress...');
            case 'todelete':
                return tr('SSL certificate revocation in progress...');
            case 'disabled':
                return tr('Deactivated');
            case 'pending':
                return tr('Pending');
            default:
                return isset($_SESSION['logged_from_type']) || $_SESSION['user_type'] == 'admin' ? $status : tr('An unexpected error occurred.');
        }
    }

    /**
     * Validate state transition of let's encrypt items
     *
     * @param string $status Current status
     * @param string $statusPrev Previous status
     * @param string $newStatus New status
     * @return bool
     */
    static public function validateStateTransition($status, $statusPrev, $newStatus)
    {
        if(!is_string($status) && null !== $status) {
            throw new \InvalidArgumentException('Invalid status');
        }

        if (!in_array($newStatus, ['toadd', 'torenew', 'todelete'], true)) {
            throw new \InvalidArgumentException('Invalid new status');
        }

        if (!in_array($statusPrev, ['toadd', 'torenew', 'todelete', null], true)) {
            throw new \InvalidArgumentException('Invalid previous status');
        }

        switch ($status) {
            case null:
                return $newStatus === 'toadd';
            case 'ok':
                // Let's Encrypt SSL certificate with status 'ok' can only be renewed or revoked
                return in_array($newStatus, ['torenew', 'todelete']);
            case 'toadd':
            case 'torenew':
            case 'todelete':
                // No action permitted if a task is already scheduled
                return false;
            case 'pending':
                // Case where a rate limit has been hit.
                // In such case only a new attempt or cancellation is allowed.
            default:
                // Case where current status holds error string
                // In such case only a new attempt or cancellation is allowed
                // except for the 'todelete' action which can be only queued
                // for a new attempt.
                if ($statusPrev == 'todelete' && $newStatus != 'todelete') {
                    return false;
                }

                return in_array($newStatus, [$statusPrev, 'todelete']);
        }
    }

    /**
     * Validate the given DNS name
     *
     * @throws \Zend_Exception
     * @param string $certName SSL certificate name (a.k.a common name), ASCII assumed
     * @param string $dnsName SSL certificate DNS name, ASCII assummed
     * @param bool $strict Flag indicating whether or not strict validation must be performed
     * @return bool TRUE if the given DNS name is valid, FALSE otherwise
     */
    static public function validateDNSname($certName, $dnsName, $strict = false)
    {
        if (!is_string($certName) || !is_string($dnsName) || !isValidDomainName($dnsName)) {
            return false;
        }

        $certName = quotemeta($certName);
        if ($strict && !preg_match("/\.$certName$/", $dnsName)) {
            return false;
        }

        return true;
    }

    /**
     * Get real identity name
     *
     * @return string
     */
    static public function getRealIdentityName()
    {
        return isset($_SESSION['logged_from']) ? $_SESSION['logged_from'] : idn_to_ascii($_SESSION['user_logged']);
    }

    /**
     * Get renewal policy in days
     *
     * @throws \Exception
     * @param int $renewalPolicyInSeconds
     * @return int
     */
    static public function getRenewalPolicyInDays($renewalPolicyInSeconds)
    {
        $renewalPolicyInSeconds = (int)$renewalPolicyInSeconds;
        if ($renewalPolicyInSeconds < 86400 || $renewalPolicyInSeconds > 7776000) {
            throw new \InvalidArgumentException('Invalid renewal policy');
        }

        $d2 = new DateTime();
        $d2->add(new DateInterval('PT' . $renewalPolicyInSeconds . 'S'));
        return $renewalPolicyInDays = $d2->diff(new DateTime())->days;
    }
}
