<?php
/**
 * i-MSCP LetsEncrypt plugin
 *
 * @author        Laurent Declercq <l.declercq@nuxwin.com>
 * @copyright (C) 2016-2018 Laurent Declercq <l.declercq@nuxwin.com>
 * @license       i-MSCP License <http://www.i-mscp.net/license-agreement.html>
 */

namespace spec\ImscpLetsEncrypt;

use PhpSpec\ObjectBehavior;

/**
 * Class UtilsSpec
 * @package spec\ImscpLetsEncrypt
 */
class UtilsSpec extends ObjectBehavior
{
    function it_return_real_identity_name()
    {
        $_SESSION['user_logged'] = 'foo';
        $this::getRealIdentityName()->shouldReturn('foo');
        $_SESSION['logged_from'] = 'bar';
        $this::getRealIdentityName()->shouldReturn('bar');
        $_SESSION = [];
    }
    
    function it_return_real_identity_name_in_ascii_form()
    {
        $_SESSION['user_logged'] = 'bürger.com';
        $this::getRealIdentityName()->shouldReturn('xn--brger-kva.com');
        $_SESSION = [];
    }

    function it_throw_an_invalid_argument_exception_on_invalid_renewal_policy()
    {
        $this::shouldThrow(new \InvalidArgumentException("Invalid renewal policy"))->during('getRenewalPolicyInDays', [0]);
        $this::shouldThrow(new \InvalidArgumentException("Invalid renewal policy"))->during('getRenewalPolicyInDays', [7776001]);
    }

    function it_convert_renewal_policy_from_seconds_to_days()
    {
        $this::getRenewalPolicyInDays(2592000)->shouldReturn(30);
        $this::getRenewalPolicyInDays(1728000)->shouldReturn(20);
        $this::getRenewalPolicyInDays(864000)->shouldReturn(10);
    }

    function it_return_expected_values_on_status_transition_validation()
    {
        $this::validateStateTransition(null, null, 'toadd')->shouldReturn(true);
        $this::validateStateTransition('ok', null, 'toadd')->shouldReturn(false);
        
        $this::validateStateTransition('ok', null, 'torenew')->shouldReturn(true);
        $this::validateStateTransition('ok', null, 'todelete')->shouldReturn(true);
        $this::validateStateTransition('ok', null, 'toadd')->shouldReturn(false);

        $this::validateStateTransition('toadd', null, 'todelete')->shouldReturn(false);
        $this::validateStateTransition('torenew', null, 'todelete')->shouldReturn(false);
        $this::validateStateTransition('todelete', null, 'todelete')->shouldReturn(false);

        $this::validateStateTransition('pending', 'toadd', 'toadd')->shouldReturn(true);
        $this::validateStateTransition('pending', 'toadd', 'todelete')->shouldReturn(true);
        $this::validateStateTransition('pending', 'toadd', 'torenew')->shouldReturn(false);

        $this::validateStateTransition('pending', 'torenew', 'torenew')->shouldReturn(true);
        $this::validateStateTransition('pending', 'torenew', 'todelete')->shouldReturn(true);
        $this::validateStateTransition('pending', 'torenew', 'toadd')->shouldReturn(false);
        
        $this::validateStateTransition('pending', 'todelete', 'todelete')->shouldReturn(true);
        $this::validateStateTransition('pending', 'todelete', 'toadd')->shouldReturn(false);
        $this::validateStateTransition('pending', 'todelete', 'torenew')->shouldReturn(false);

        $this::validateStateTransition('foo', 'toadd', 'toadd')->shouldReturn(true);
        $this::validateStateTransition('foo', 'toadd', 'todelete')->shouldReturn(true);
        $this::validateStateTransition('foo', 'toadd', 'torenew')->shouldReturn(false);

        $this::validateStateTransition('foo', 'torenew', 'torenew')->shouldReturn(true);
        $this::validateStateTransition('foo', 'torenew', 'todelete')->shouldReturn(true);
        $this::validateStateTransition('foo', 'torenew', 'toadd')->shouldReturn(false);

        $this::validateStateTransition('foo', 'todelete', 'todelete')->shouldReturn(true);
        $this::validateStateTransition('foo', 'todelete', 'toadd')->shouldReturn(false);
        $this::validateStateTransition('foo', 'todelete', 'torenew')->shouldReturn(false);
    }

    function it_throw_an_invalid_argument_exception_on_invalid_status_when_validating_status_transition()
    {
        $this::shouldThrow(new \InvalidArgumentException("Invalid status"))->during('validateStateTransition', [[], 'toadd', 'toadd']);
        $this::shouldThrow(new \InvalidArgumentException("Invalid status"))->during('validateStateTransition', [10, 'toadd', 'toadd']);
        $this::shouldThrow(new \InvalidArgumentException("Invalid status"))->during('validateStateTransition', [new \stdClass(), 'toadd', 'toadd']);
    }

    function it_throw_an_invalid_argument_exception_on_invalid_new_status_when_validating_status_transition()
    {
        $this::shouldThrow(new \InvalidArgumentException("Invalid new status"))->during('validateStateTransition', ['pending', 'toadd', 'foo']);
    }

    function it_throw_an_invalid_argument_exception_on_invalid_previous_status_when_validating_status_transition()
    {
        $this::shouldThrow(new \InvalidArgumentException("Invalid previous status"))->during('validateStateTransition', ['pending', 'foo', 'toadd']);
    }
}
