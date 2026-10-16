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

# This script responsible for automatic renewal of SSL certificate which are
# due for renewal, according the renewal policy. It is  automatically added
# as a cron job in the i-MSCP core cron file (e.g. /etc/cron.d/imscp).
#
# This script can also be run manually by administrator.

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
exit unless $bootstrapper->lock( '/var/lock/imscp-letsencrypt-renew.lock', 'nowait' );

eval {
    newDebug( 'letsencrypt-plugin-renew.pl.log' );

    iMSCP::Getopt->parseNoDefault( sprintf( 'Usage: perl %s [OPTION]...', basename( $0 )) . qq{

Process renewal tasks.

OPTIONS:
 -d,    --debug         Enable debug mode.
 -v,    --verbose       Enable verbose mode.},
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
            SET letsencrypt_status = 'torenew', letsencrypt_previous_status = NULL, letsencrypt_status_date = UNIX_TIMESTAMP()
            WHERE letsencrypt_status = 'ok'
            AND letsencrypt_expires <= UNIX_TIMESTAMP() + ?
        ",
        getConfig( $db )->{'renewal_policy'} // 1814400
    );
    ref $qrs eq 'HASH' or die( $qrs );

    iMSCP::DbTasksProcessor->getInstance( mode => 'backend' )->process();
};
if ( $@ ) {
    error( sprintf( "Couldn't process Let's Encrypt renewal tasks: %s", $@ ) );
    exit 1;
}

END { $bootstrapper->unlock( '/var/lock/imscp-letsencrypt-renew.lock' ); }

1;
__END__;
