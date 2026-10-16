#!/usr/bin/perl

# i-MSCP LetsEncrypt plugin
#
# @author Laurent Declercq <l.declercq@nuxwin.com>
# @copyright (C) 2016-2018 Laurent Declercq <l.declercq@nuxwin.com>
# @license i-MSCP License <http://www.i-mscp.net/license-agreement.html>

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../../../engine/PerlLib", "$FindBin::Bin/../../../../engine/PerlVendor";
use Class::Autouse qw/ :nostat iMSCP::Database iMSCP::DbTasksProcessor iMSCP::Service /;
use File::Basename;
use iMSCP::Bootstrapper;
use iMSCP::Debug;
use iMSCP::Getopt;
use JSON;

# This script is responsible for processing of pending tasks, that is, the
# tasks that were queued for later processing due to a Let's Encrypt rate
# limit hit, or technical problem such as service outage. It is automatically
# added as a cron job in the i-MSCP core cron file (e.g. /etc/cron.d/imscp).
#
# This script, which can be run manually by administrator, also provides a
# '--now' flag, making possible to force the processing of the pending tasks,
# regardless of the waiting time policy.

sub getConfig
{
    my ($db) = @_;
    my $dbi = $db->getRawDb();

    local $dbi->{'RaiseError'} = 1;

    my $config = $dbi->selectrow_hashref( "SELECT plugin_config FROM plugin WHERE plugin_name = 'LetsEncrypt'" );
    $config or die( "Couldn't find LetsEncrypt plugin configuration in database" );
    JSON->new()->decode( $config->{'plugin_config'} );
}

my $bootstrapper = iMSCP::Bootstrapper->getInstance();
exit unless $bootstrapper->lock( '/var/lock/imscp-letsencrypt-pending.lock', 'nowait' );

eval {
    newDebug( 'letsencrypt-plugin-pending.pl.log' );

    iMSCP::Getopt->parseNoDefault( sprintf( 'Usage: perl %s [OPTION]...', basename( $0 )) . qq{

Process pending tasks.

OPTIONS:
 -n,    --now           Force immediate processing of pending tasks
 -d,    --debug         Enable debug mode.
 -v,    --verbose       Enable verbose mode.},
        'now|n'     => \my $now,
        'debug|d'   => \&iMSCP::Getopt::debug,
        'verbose|v' => \&iMSCP::Getopt::verbose
    );

    setVerbose( iMSCP::Getopt->verbose );

    iMSCP::Bootstrapper->getInstance()->boot( {
        config_readonly => 'yes',
        norequirements  => 'yes'
    } );

    my $db = iMSCP::Database->factory();
    my $qrs = $db->doQuery(
        'u',
        "
            UPDATE letsencrypt
            SET letsencrypt_status = letsencrypt_previous_status, letsencrypt_previous_status = NULL, letsencrypt_status_date = UNIX_TIMESTAMP()
            WHERE letsencrypt_status = 'pending'
        " . ( $now ? '' : ' AND letsencrypt_status_date + ? <= UNIX_TIMESTAMP()' ),
        ( $now ? () : getConfig( $db )->{'pending_policy'} // 3600 ),
    );
    ref $qrs eq 'HASH' or die( $qrs );

    iMSCP::DbTasksProcessor->getInstance( mode => 'backend' )->process();
};
if ( $@ ) {
    error( sprintf( "Couldn't process Let's Encrypt pending tasks: %s", $@ ) );
    exit 1;
}

END { $bootstrapper->unlock( '/var/lock/imscp-letsencrypt-pending.lock' ); }

1;
__END__
