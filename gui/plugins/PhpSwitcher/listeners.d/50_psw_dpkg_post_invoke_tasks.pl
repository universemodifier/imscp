# i-MSCP PhpSwitcher plugin
#
# @author Laurent Declercq <l.declercq@nuxwin.com>
# @copyright (C) 2014-2019 Laurent Declercq <l.declercq@nuxwin.com>
# @license i-MSCP License <https://www.i-mscp.net/license-agreement.html>

# Registers an event listener that listens on the
# beforeFrontEndDpkgPostInvokeTasks event to update the various packaged PHP
# versions when those are being updated by the sysadmin:
#
# For a given packaged PHP version two action can be scheduled:
# - It deletion if one of its requirement is not longer meet after the DPKG(1)
#   post-invoke tasks
# - It full reconfiguration if the version (e.g. minor version changed)
#
# /!\ This listener file has been installed by the PhpSwitcher plugin.
# Please don't remove it /!\

package Listener::PhpSwitcher::DpkgPostInvokeTasks;

use strict;
use warnings;
use iMSCP::Bootstrapper;
use iMSCP::Database;
use iMSCP::DbTasksProcessor;
use iMSCP::Debug qw/ debug error /;
use iMSCP::Execute 'execute';
use iMSCP::EventManager;
use JSON;

iMSCP::EventManager->getInstance()->register(
    'beforeFrontEndDpkgPostInvokeTasks',
    sub
    {
        my $rs = eval {
            iMSCP::Bootstrapper->getInstance()->lock();

            return 0 unless defined( my $plugin = _getPhpSwitcherPlugin() );

            my $phpVersions = $plugin->getPhpVersions();
            for my $phpVersion ( values %{ $phpVersions } ) {
                # We want process only known packaged PHP versions, that is,
                # those that were already registered as such.
                next unless $phpVersion->{'version_is_packaged'};

                # The packaged PHP version has been removed by the sysadmin
                # We need schedule it deletion
                if ( _isPackagedPhpVersionDeletionNeeded(
                    $plugin, $phpVersion
                ) ) {
                    debug( sprintf(
                        "Scheduling deletion of the packaged PHP %s version. One of its requirements is not longer meet after the DPKG(1) post-invoke tasks.",
                        $phpVersion->{'version_name'}
                    ));
                    $phpVersion->{'version_status'} = 'todelete';
                    next;
                }

                # Packaged PHP version has been updated through APT (version
                # doesn't remain identical after the DPKG(1) post-invoke tasks).
                # We need schedule a reconfiguration.
                if ( _isPackagedPhpVersionReconfigurationNeeded(
                    $phpVersion
                ) ) {
                    debug( sprintf(
                        "Scheduling reconfiguration of the packaged PHP %s version. The version changed after the DPKG(1) post-invoke tasks.",
                        $phpVersion->{'version_name'}
                    ));
                    $phpVersion->{'version_status'} = 'tochange';
                    next;
                }

                debug( sprintf(
                    "No change detected for the packaged PHP %s version after the DPKG(1) post-invoke tasks. Skipping...",
                    $phpVersion->{'version_name'}
                ));
            }

            # Process scheduled tasks
            iMSCP::DbTasksProcessor
                ->getInstance( mode => 'backend' )
                ->processDbTasks();

            0;
        };
        if ( $@ ) {
            error( $@ );
            $rs = 1;
        }

        $rs;
    }
);

sub _getPhpSwitcherPlugin
{
    my $dbh = iMSCP::Database->factory()->getRawDb();

    local $dbh->{'RaiseError'} = 1;

    my $row = $dbh->selectrow_hashref(
        "
            SELECT `plugin_config` AS 'config',
                `plugin_config_prev` AS 'config_prev'
            FROM `plugin`
            WHERE `plugin_name` = 'PhpSwitcher'
            AND `plugin_status` = 'enabled'
        "
    );

    return unless $row;

    $_ = decode_json( $_ ) for values %{ $row };

    require "$::imscpConfig{'PLUGINS_DIR'}/PhpSwitcher/backend/PhpSwitcher.pm";

    Plugin::PhpSwitcher->getInstance( {
        action                          => 'run',
        eventManager                    => iMSCP::EventManager->getInstance(),
        noFullPhpVersionsReconfiguration => 1,
        %{ $row }
    } );
}

sub _isPackagedPhpVersionDeletionNeeded( $$ )
{
    my ( $plugin, $phpVersion ) = @_;

    # Force a new check to make sure that all requirements are met for use of
    # the packaged PHP version (cover case where the sysadmin removed a
    # required  package (e.g. php%VERSION%-cgi, php%VERSION%-fpm or php-pear).
    local $phpVersion->{'version_is_packaged'} = undef;

    $plugin->isPackagedPhpVersion( $phpVersion ) ? 0 : 1;
}

sub _isPackagedPhpVersionReconfigurationNeeded( $ )
{
    my ( $phpVersion ) = @_;

    my $versionPattern = qr/^PHP\s+((?:\d+.){2}\d+)((?:alpha|beta|RC)\d+)?/;

    my ( $stdout, $stderr );
    execute(
        [ $phpVersion->{'version_cgi_binary_path'}, '-n', '-v' ],
        \$stdout,
        \$stderr
    ) == 0 or die( sprintf(
        "Couldn't get PHP version through the '%s' executable: %s\n",
        $phpVersion->{'version_cgi_binary_path'},
        $stderr
    ));

    $stdout =~ /$versionPattern.*?\s+\(cgi-fcgi\)/ or die( sprintf(
        "'%s' doesn't look like a PHP FastCGI binary.\n",
        $phpVersion->{'version_cgi_binary_path'}
    ));

    my ( $major, $minor, $tiny, $stage ) = ( split( /\./, $1 ), $2 // '' );

    "$major.$minor.$tiny$stage" ne $phpVersion->{'version_version'};
}

1;
__END__
