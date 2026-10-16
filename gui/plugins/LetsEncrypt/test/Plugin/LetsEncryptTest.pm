# i-MSCP LetsEncrypt plugin
#
# @author Laurent Declercq <l.declercq@nuxwin.com>
# @copyright (C) 2016-2018 Laurent Declercq <l.declercq@nuxwin.com>
# @license i-MSCP License <http://www.i-mscp.net/license-agreement.html>

# TO BE COMPLETED

package Plugin::LetsEncryptTest;

use strict;
use warnings;
use iMSCP::Debug;
use iMSCP::EventManager;
use Test::More;

setDebug( 0 );
setVerbose( 0 );

my $assetDir;

sub getPluginInstanceParams
{
    (
        action       => 'run',
        config       => {
            certbot_path             => '/usr/local/sbin/certbot-auto',
            certbot_version          => 'released',
            certbot_self_upgrade     => 1,
            certbot_create_options   => [ '--staging' ],
            certbot_revoke_options   => [ '--staging' ],
            letsencrypt_storage_path => "/etc/letsencrypt",
            pending_policy           => 3600,
            renewal_policy           => 2592000,
            cronjob_renew            => {
                minute => '@daily',
                hour   => '',
                day    => '',
                month  => '',
                dweek  => ''
            },
            cronjob_pending          => {
                minute => '@hourly',
                hour   => '',
                day    => '',
                month  => '',
                dweek  => ''
            }
        },
        eventManager => iMSCP::EventManager->getInstance()
    );
}

sub getNewPluginInstance
{
    Plugin::LetsEncrypt->new( @_ );
}

sub initDieOnMissingPluginConfigurationParameters
{
    my %params = getPluginInstanceParams();
    delete $params{'config'}->{'certbot_path'};
    local $@;
    eval { getNewPluginInstance( %params ); };
    $@ && $@ =~ /Missing 'certbot_path' configuration parameter/;
}

sub getExpectedIssuerCommonName
{
    my $plugin = getNewPluginInstance( getPluginInstanceParams());
    my $x509 = $plugin->_decodePemCert( "$assetDir/fake.pem", 'domain.tld', 'www.domain.tld' );
    my $issuerCommonName = $plugin->_getIssuerCommonName( $x509 );
    $issuerCommonName eq 'Fake SSL certificate';
}

sub getExpectedExpiryDate
{
    my $plugin = getNewPluginInstance( getPluginInstanceParams());
    my $x509 = $plugin->_decodePemCert( "$assetDir/fake.pem", 'domain.tld', 'www.domain.tld' );
    my $expiryDate = $plugin->_getCertExpiryDate( $x509 );
    $expiryDate == 1794916139;
}

sub getExpectedDnsNames
{
    my $plugin = getNewPluginInstance( getPluginInstanceParams());
    my $x509 = $plugin->_decodePemCert( "$assetDir/fake.pem", 'domain.tld', 'www.domain.tld' );
    $plugin->_getCertDNSnames( $x509 );
}

sub certActionIsIssueForNewCertificate
{
    my $plugin = getNewPluginInstance( getPluginInstanceParams());
    $plugin->_getCertRequiredAction( "$assetDir/missing.pem", 'domain.tld', 'www.domain.tld' ) eq 'issue';
}

sub certActionIsIssueForExpiredCertificate
{
    my $plugin = getNewPluginInstance( getPluginInstanceParams());
    $plugin->_getCertRequiredAction( "$assetDir/expired.pem", 'domain.tld', 'www.domain.tld' ) eq 'renew';
}

sub certActionIsIssueWhenSwitchingCA
{
    my %params = getPluginInstanceParams();
    $params{'config'}->{'certbot_create_options'} = [];
    my $plugin = getNewPluginInstance( %params );
    $plugin->_getCertRequiredAction( "$assetDir/fake.pem", 'domain.tld', 'www.domain.tld' ) eq 'issue';
}

sub certActionIsExpandWhenAddingDNSnames
{
    my $plugin = getNewPluginInstance( getPluginInstanceParams());
    $plugin->_getCertRequiredAction( "$assetDir/fake.pem", 'domain.tld', 'www.domain.tld', 'foo.domain.tld' ) eq 'expand';
}

sub certActionIsShrinkWhenRemovingSans
{
    my $plugin = getNewPluginInstance( getPluginInstanceParams());
    $plugin->_getCertRequiredAction( "$assetDir/fake.pem", 'domain.tld' ) eq 'shrink';
}

sub certActionIsRenewWhenCertIsNearExpiry
{
    my %params = getPluginInstanceParams();
    $params{'config'}->{'renewal_policy'} = ( 1794916139-( time+2592000 ) )+2592000;
    my $plugin = getNewPluginInstance( %params );
    $plugin->_getCertRequiredAction( "$assetDir/fake.pem", 'domain.tld', 'www.domain.tld' ) eq 'renew';
}

sub certActionIsNoneWhenCertIsStillValidAndNoDNSnameChanges
{
    my $plugin = getNewPluginInstance( getPluginInstanceParams());
    $plugin->_getCertRequiredAction( "$assetDir/fake.pem", 'domain.tld', 'www.domain.tld' ) eq 'none';
}

sub getExpectedStatusesFromErrorStrings
{
    my $plugin = getNewPluginInstance( getPluginInstanceParams());
    $plugin->_getNewStatusFromErrorString( 'toadd', undef ) eq 'Unknown error'
        && $plugin->_getNewStatusFromErrorString( 'toadd', 'Too many certificates already issued' ) eq 'pending'
        && $plugin->_getNewStatusFromErrorString( 'toadd', 'Global certificate issuance limit reached' ) eq 'pending'
        && $plugin->_getNewStatusFromErrorString( 'toadd', 'Too many currently pending authorizations' ) eq 'pending'
        && $plugin->_getNewStatusFromErrorString( 'toadd', 'too many invalid authorizations recently' ) eq 'pending'
        && $plugin->_getNewStatusFromErrorString( 'toadd', 'Too many registrations from this ip' ) eq 'pending'
        && $plugin->_getNewStatusFromErrorString( 'todelete', 'Certificate already revoked' ) eq 'todelete'
        && $plugin->_getNewStatusFromErrorString( 'todelete', 'no such certificate' ) eq 'todelete'
        && $plugin->_getNewStatusFromErrorString( 'todelete', 'no existing certificates found' ) eq 'todelete'
        && $plugin->_getNewStatusFromErrorString( 'todelete', 'foor bar' ) eq 'pending'
        && $plugin->_getNewStatusFromErrorString( 'toadd', 'foo bar' ) eq 'foo bar';
}

sub runUnitTests
{
    $assetDir = shift;
    plan tests => 13; # Number of tests planned for execution

    return unless require_ok( 'LetsEncrypt' );

    eval {
        ok initDieOnMissingPluginConfigurationParameters, ' _init() die on missing plugin configuration parameters';
        ok getExpectedIssuerCommonName, " _getIssuerCommonName return expected issuer common name";
        ok getExpectedExpiryDate, " _getCertExpiryDate return expected expiry date";
        is_deeply [ getExpectedDnsNames() ], [ sort qw/ domain.tld www.domain.tld / ], " _getCertDNSnames return expected DNS names";
        ok certActionIsIssueForNewCertificate, " _getCertRequiredAction return 'issue 'when SSL certificate doesn't exists";
        ok certActionIsIssueForExpiredCertificate, " _getCertRequiredAction return 'return 'when SSL certificate is expired";
        ok certActionIsIssueWhenSwitchingCA, " _getCertRequiredAction return 'issue' when switching CA (staging to production environment)";
        ok certActionIsExpandWhenAddingDNSnames, " _getCertRequiredAction return 'expand' when adding DNS names";
        ok certActionIsShrinkWhenRemovingSans, " _getCertRequiredAction return 'shrink' when removing DNS names";
        ok certActionIsRenewWhenCertIsNearExpiry, "_getCertRequiredAction return 'renew' when SSL certificate is near expiry";
        ok certActionIsNoneWhenCertIsStillValidAndNoDNSnameChanges, "_getCertRequiredAction return 'none' when SSL certificate is still valid and when there are no DNS name changes";
        ok getExpectedStatusesFromErrorStrings, "_getStatusFromErrorString return expected statuses";
    };

    fail sprintf( 'A test failed unexpectedly: %s', $@ ) if $@;
}

1;
__END__
