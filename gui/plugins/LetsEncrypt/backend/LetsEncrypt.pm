=head1 NAME

 Plugin::LetsEncrypt

=cut

# i-MSCP LetsEncrypt plugin
#
# @author Laurent Declercq <l.declercq@nuxwin.com>
# @copyright (C) 2016-2018 Laurent Declercq <l.declercq@nuxwin.com>
# @license i-MSCP License <http://www.i-mscp.net/license-agreement.html>

package Plugin::LetsEncrypt;

use strict;
use warnings;
use autouse 'iMSCP::Execute' => qw/ execute /;
use autouse 'iMSCP::Rights' => qw/ setRights /;
use autouse 'MIME::Base64' => qw/ decode_base64 /;
use Class::Autouse qw/ :nostat
    Array::Diff Convert::ASN1 DateTime::Format::Strptime File::HomeDir iMSCP::Dir iMSCP::File iMSCP::Plugins iMSCP::Service Package::FrontEnd
    Servers::cron Servers::ftpd Servers::httpd Servers::mta Servers::po /;
use iMSCP::Debug qw/ debug error getMessageByType /;
use iMSCP::Database;
use JSON;
use List::MoreUtils qw/ uniq /;
use version;
use parent 'Common::Object';

=head1 DESCRIPTION

 This package implements the backend side of the LetsEncrypt plugin.

=head1 PUBLIC METHODS

=over 4

=item registerSetupListeners( \%eventManager )

 Register setup event listeners

 Param iMSCP::EventManager \%eventManager
 Return int 0 on success, other on failure

=cut

sub registerSetupListeners
{
    my ( $class, $eventManager ) = @_;

    $eventManager->register( 'afterCronInstall', sub { $class->onAfterCronInstall( $eventManager ); } );
}

=item install ( )

 Process installation tasks

 return int 0 on success, 1 on failure

=cut

sub install
{
    my ( $self ) = @_;

    eval { $self->_installDistributionPackages() };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    0;
}

=item uninstall ( )

 Process uninstallation tasks

 return int 0 on success, 1 on failure

=cut

sub uninstall
{
    my ( $self ) = @_;

    eval { iMSCP::Dir->new( dirname => $_ )->remove() for '/opt/imscp-certbot', $self->_getVirtualEnvPaths(); };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    0;
}

=item update( $fromVersion )

 Process update tasks

 Param string $fromVersion Version from which the plugin is being updated
 return int 0 on success, 1 on failure

=cut

sub update
{
    my ( $self, $fromVersion ) = @_;

    eval {
        # Make sure that all required distribution packages are installed
        $self->_installDistributionPackages();

        $fromVersion = version->parse( $fromVersion );

        return unless $fromVersion < version->parse( '3.5.0' );

        # Fix SSL certificate expiry date in database
        local $self->{'_dbh'}->{'RaiseError'} = 1;
        my $sth = $self->{'_dbh'}->prepare(
            "SELECT letsencrypt_id, domain_name FROM letsencrypt WHERE letsencrypt_status = 'ok' GROUP BY domain_name"
        );
        $sth->execute();
        while ( my $row = $sth->fetchrow_hashref() ) {
            my $liveCertPath = "$self->{'config'}->{'letsencrypt_storage_path'}/live/$row->{'domain_name'}/cert.pem";
            next unless -f $liveCertPath;
            $self->{'_dbh'}->do(
                'UPDATE letsencrypt SET letsencrypt_expires = ? WHERE letsencrypt_id = ?',
                undef,
                ( eval { $self->_getCertExpiryDate( $self->_decodePemCert( $liveCertPath, 'force' )); } || $row->{'letsencrypt_expires'} ),
                $row->{'letsencrypt_id'}
            );
        }
        $self->{'_x509'} = {};

        return unless $fromVersion < version->parse( '3.4.0' );

        # Remove venv from old location (old was in most cases /root/.local/share/letsencrypt, new is /opt/eff.org/certbot/venv)
        iMSCP::Dir->new( dirname => ( $self->_getVirtualEnvPaths() )[0] )->remove();

        return unless $fromVersion < version->parse( '3.3.0' );

        # Remove certbot-auto (it is now only used while plugin installation/update
        iMSCP::File->new( filename => "/usr/local/sbin/certbot-auto" )->delFile() == 0 or die(
            getMessageByType( 'error', { remove => 1, amount => 1 } ) || 'Unknown error'
        ) if -f '/usr/local/sbin/certbot-auto';

        # Remove deprecated directory for ACME challenges
        iMSCP::Dir->new( dirname => "$main::imscpConfig{'USER_WEB_DIR'}/LetsEncrypt" )->remove();

        my $httpd = Servers::httpd->factory();

        # Remove deprecated configuration files that were not purged correctly
        # in older versions
        for ( 'LetsEncrypt.conf', 'vhost.conf', 'letsencrypt_vhost.conf' ) {
            next unless -f "$httpd->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'}/before/$_";
            iMSCP::File->new( filename => "$httpd->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'}/before/$_" )->delFile() == 0 or die(
                getMessageByType( 'error', { remove => 1, amount => 1 } ) || 'Unknown error'
            );
            $httpd->{'restart'} = 1;
        }

        # Remove deprecated Apache2 vhost files
        for ( $main::imscpConfig{'BASE_SERVER_VHOST'}, $main::imscpConfig{'SERVER_HOSTNAME'} ) {
            next unless -f "$httpd->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$_.conf" && !$self->getCustomerDomainIdAndType( $_ );
            $httpd->disableSites( "$_.conf" ) == 0
                && iMSCP::File->new( filename => "$httpd->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$_.conf" )->delFile() == 0 or die(
                getMessageByType( 'error', { remove => 1, amount => 1 } ) || 'Unknown error'
            );
        }

        # Remove deprecated vhost file that was not removed correctly in previous versions
        if ( -f "$httpd->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/letsencrypt_vhost.conf'" ) {
            $httpd->disableSites( "letsencrypt_vhost.conf" ) == 0
                && iMSCP::File->new( filename => "$httpd->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/letsencrypt_vhost.conf" )->delFile() == 0 or die(
                getMessageByType( 'error', { remove => 1, amount => 1 } ) || 'Unknown error'
            );
        }

        return unless $fromVersion < version->parse( '1.4.0' );

        # Force administrator to re-enable SSL for the control panel and/or services due to major issues in previous version
        $self->{'_dbh'}->do( 'DELETE FROM letsencrypt WHERE admin_id IS NULL' );
        # Force new processing of all customers SSL certificates due to misplaced
        # SQL statement in previous versions. We say 'renew' here but the real
        # action to be performed will be determined by processor.
        $self->{'_dbh'}->do(
            "
                UPDATE letsencrypt
                SET letsencrypt_status = 'torenew', letsencrypt_previous_status = NULL, letsencrypt_status_date = UNIX_TIMESTAMP()
                WHERE admin_id IS NOT NULL
                AND letsencrypt_status <> 'todelete'
            "
        );
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    0;
}

=item enable( )

 Process enable tasks

 Return int 0 on success, 1 on failure

=cut

sub enable
{
    my ( $self ) = @_;

    eval {
        return if defined $main::execmode && $main::execmode eq 'setup';

        # Ensure idempotence
        # Only needed for the 'install' and 'enable' actions as the 'disable'
        # action is a subaction of both the 'update' and 'change' actions.
        # The 'install' action is covered only for safety.
        if ( grep ($self->{'action'} eq $_, 'install', 'enable') ) {
            $self->disable() == 0 or die( getMessageByType( 'error', { remove => 1, amount => 1 } ) || 'Unknown error' );
        }

        $self->_createHttpdConfig();
        $self->_addCronjob( 'pending' );
        $self->_addCronjob( 'renew' );

        if ( grep (
            m%--(?:test-cert|staging|(?:server\s+\Qhttps://acme-staging\E))%,
            @{ $self->{'config'}->{'certbot_create_options'} }, @{ $self->{'config'}->{'certbot_create_options'} })
        ) {
            # Add the Let's Encrypt 'Fake LE Root X1' root certificate in SSL
            # certificate store (staging environment -- testing purpose only).
            iMSCP::Dir->new( dirname => '/usr/local/share/ca-certificates' )->make( {
                user  => $main::imscpConfig{'ROOT_USER'},
                group => 'staff',
                mode  => 2775
            } );
            iMSCP::File->new( filename => "$main::imscpConfig{'PLUGINS_DIR'}/LetsEncrypt/resources/staging/fakelerootx1.crt" )->copyFile(
                '/usr/local/share/ca-certificates', { preserve => 'no' }
            ) == 0 or die( getMessageByType( 'error', { remove => 1, amount => 1 } ) || 'Unknown error' );
        }

        local $ENV{'DEBIAN_FRONTEND'} = 'noninteractive';
        my ( $stdout, $stderr );
        my $rs = execute( 'update-ca-certificates', \$stdout, \$stderr ) == 0 or die( $stderr || 'Unknown error' );
        debug( $stdout ) if $stdout;

        if ( $self->{'action'} eq 'install' ) {
            # On fresh installation, make sure to start with a clean environment
            iMSCP::Dir->new( dirname => $_ )->remove() for '/opt/imscp-certbot', $self->_getVirtualEnvPaths();
        }

        # Process installation of Certbot client.
        # certbot-auto does not run on current Python. Use the distribution client.
        if ( $self->{'config'}->{'certbot_version'} eq 'develop' ) {
            $self->_runCertbotFromDevelop();
        } else {
            my $systemCertbot = '/usr/bin/certbot';
            -x $systemCertbot or die( "Couldn't find the certbot client at $systemCertbot" );

            if ( $self->{'config'}->{'certbot_path'} ne $systemCertbot ) {
                unlink $self->{'config'}->{'certbot_path'} if -l $self->{'config'}->{'certbot_path'};
                symlink( $systemCertbot, $self->{'config'}->{'certbot_path'} ) or die( sprintf(
                    "Couldn't create symlink to certbot client: %s", $!
                ));
            }

            execute( [ $systemCertbot, '--version' ], \$stdout, \$stderr ) == 0 or die( $stderr || $stdout );
            debug( $stdout ) if $stdout;
        }

        # Reload Apache2 immediately to make the new configuration effective
        iMSCP::Service->getInstance()->reload( Servers::httpd->factory()->{'config'}->{'HTTPD_SNAME'} );
        $self->run();
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    0;
}

=item disable( )

 Process disable tasks

 Return int 0 on success, 1 on failure

=cut

sub disable
{
    my ( $self ) = @_;

    eval {
        return if defined $main::execmode && $main::execmode eq 'setup';

        $self->_deleteHttpdConfig();
        $self->_deleteCronjob( 'pending' );
        $self->_deleteCronjob( 'renew' );

        if ( -l $self->{'config_prev'}->{'certbot_path'} ) {
            iMSCP::File->new( filename => $self->{'config_prev'}->{'certbot_path'} )->delFile() == 0 or die(
                getMessageByType( 'error', { remove => 1, amount => 1 } ) || 'Unknown error'
            );
        }

        for ( '/opt/certbot.log', '/usr/local/share/ca-certificates/fakelerootx1.crt' ) {
            next unless -f;
            iMSCP::File->new( filename => $_ )->delFile() == 0 or die( getMessageByType( 'error', { remove => 1, amount => 1 } ) || 'Unknown error' );
        }

        iMSCP::Dir->new( dirname => $_ )->remove() for '/var/lib/letsencrypt', '/var/log/letsencrypt';

        if ( $self->{'action'} eq 'update' ) {
            iMSCP::Dir->new( dirname => $_ )->remove() for '/opt/imscp-certbot', ( $self->_getVirtualEnvPaths() )[1];
        }

        my ( $stdout, $stderr );
        execute( [ 'update-ca-certificates', '--fresh' ], \$stdout, \$stderr ) == 0 or die( $stderr || 'Unknown error' );
        debug( $stdout ) if $stdout;

        Servers::httpd->factory()->{'restart'} = 1 if $self->{'action'} eq 'disable';
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    0;
}

=item run( )

 Process plugin tasks

 Return int 0 on success, other on failure

=cut

sub run
{
    my ( $self ) = @_;

    eval {
        return unless iMSCP::Service->getInstance()->isRunning( 'apache2' );

        local $self->{'_dbh'}->{'RaiseError'} = 1;
        my $sth = $self->{'_dbh'}->prepare( "SELECT * FROM letsencrypt WHERE letsencrypt_status IN('toadd', 'torenew', 'todelete')" );
        $sth->execute();

        while ( my $certData = $sth->fetchrow_hashref() ) {
            my $status = $certData->{'letsencrypt_status'};
            my $liveCertPath = "$self->{'config'}->{'letsencrypt_storage_path'}/live/$certData->{'domain_name'}/cert.pem";

            debug( sprintf( "Executing '%s' tasks for the '%s' SSL certificate", $certData->{'letsencrypt_status'}, $certData->{'domain_name'} ));
            $self->{'_dbh'}->begin_work();

            eval {
                if ( $certData->{'letsencrypt_status'} ne 'todelete' ) {
                    $self->_issueCertificate( $certData );
                    $self->_readCertDataFromFiles( $certData );
                } else {
                    $self->_revokeCertificate( $certData );
                }

                if ( $certData->{'letsencrypt_status'} ne 'todelete' && $self->_isSharedLineage( $certData->{'domain_name'} ) ) {
                    for ( values %{ $self->getEntitiesWithSharedLineage( $certData->{'domain_name'} ) } ) {
                        $_->{'files'} = $certData->{'files'} // {};
                        $_->{'letsencrypt_status'} = $certData->{'letsencrypt_status'};

                        if ( $_->{'domain_type'} !~ /^(?:control_panel|services)$/ ) {
                            $self->_handleCustomerSSLcertificate( $_ );
                            $self->_scheduleDomainChange( $_->{'domain_id'}, $_->{'domain_type'} );
                            next;
                        }

                        $self->_handleSystemSSLcertificate( $_ );
                    }
                } elsif ( $certData->{'domain_type'} !~ /^(?:control_panel|services)$/ ) {
                    $self->_handleCustomerSSLcertificate( $certData );
                    $self->_scheduleDomainChange( $certData->{'domain_id'}, $certData->{'domain_type'} );
                } else {
                    $self->_handleSystemSSLcertificate( $certData );
                }
            };
            $status = $self->_getNewStatusFromErrorString( $certData->{'letsencrypt_status'}, $@ ) if $@;

            # Update Let's Encrypt items in database
            # On error, and if the item status was 'todelete', we only
            # update entry for that item, else, we update any entry matching
            # the domain name (covers case of shared SSL certificate lineage)
            my $isError = ( $status !~ /^to(?:add|renew|delete)$/ );
            if ( $isError || $status ne 'todelete' ) {
                $self->{'_dbh'}->do(
                    '
                        UPDATE letsencrypt
                        SET letsencrypt_status = ?, letsencrypt_previous_status = ?, letsencrypt_status_date = UNIX_TIMESTAMP(),
                            letsencrypt_expires = ?
                        WHERE ' . ( $isError && $certData->{'letsencrypt_status'} eq 'todelete' ? 'letsencrypt_id' : 'domain_name' ) . ' = ?
                    ',
                    undef,
                    ( $isError ? $status : 'ok' ),
                    ( $isError ? $certData->{'letsencrypt_status'} : undef ),
                    ( eval { $self->_getCertExpiryDate( $self->_decodePemCert( $liveCertPath, 'force' )); } || $certData->{'letsencrypt_expires'} ),
                    ( $isError && $certData->{'letsencrypt_status'} eq 'todelete' ? $certData->{'letsencrypt_id'} : $certData->{'domain_name'} )
                );
            }

            $self->{'_dbh'}->commit();
            delete $self->{'_x509'}->{$liveCertPath};
        }
    };
    if ( $@ ) {
        $self->{'_dbh'}->rollback();
        $self->{'FORCE_RETVAL'} = 1;
        error( $@ );
        return 1;
    }

    0;
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init( )

 Initialize plugin

 Return Plugin::LetsEncrypt

=cut

sub _init
{
    my ( $self ) = @_;

    for ( qw/ certbot_path certbot_version certbot_create_options certbot_revoke_options letsencrypt_storage_path cronjob_renew cronjob_pending
        pending_policy renewal_policy /
    ) {
        die( sprintf( "Missing '%s' configuration parameter", $_ )) unless exists $self->{'config'}->{$_};
    }

    $self->{'_x509'} = {};
    $self->{'_dbh'} = iMSCP::Database->factory()->getRawDb();
    $self;
}

=item _installDistributionPackages( )

 Install distribution packages

 Return void, die on failure

=cut

sub _installDistributionPackages
{
    local $ENV{'DEBIAN_FRONTEND'} = 'noninteractive';

    my ( $stdout, $stderr );
    execute(
        [
            'apt-get', '--assume-yes', '--no-install-recommends', '--quiet', 'install', 'ca-certificates', 'certbot', 'git', 'libarray-diff-perl',
            'libconvert-asn1-perl', 'libdatetime-format-strptime-perl', 'lsb-release'
        ],
        \$stdout, \$stderr
    ) == 0 or die( $stderr || 'Unknown error' );
    debug( $stdout ) if $stdout;
}

=item _createHttpdConfig( )

 Create httpd configuration files for ACME challenges (domain validations)

 Return void, die on failure

=cut

sub _createHttpdConfig
{
    my $httpd = Servers::httpd->factory();
    $httpd->setData( {
        HTTPD_USER  => $httpd->{'config'}->{'HTTPD_USER'},
        HTTPD_GROUP => $httpd->{'config'}->{'HTTPD_GROUP'},
        PLUGINS_DIR => $main::imscpConfig{'PLUGINS_DIR'}
    } );
    $httpd->buildConfFile( "$main::imscpConfig{'PLUGINS_DIR'}/LetsEncrypt/templates/apache2/LetsEncrypt_Alias.conf", {}, {
        destination => "$httpd->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'}/before/LetsEncrypt_Alias.conf"
    } ) == 0 or die( getMessageByType( 'error', { remove => 1, amount => 1 } ) || 'Unknown error' )
}

=item _deleteHttpdConfig( )

 Delete httpd configuration file

 Return void, die on failure

=cut

sub _deleteHttpdConfig
{
    my $httpd = Servers::httpd->factory();

    return unless -f "$httpd->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'}/before/LetsEncrypt_Alias.conf";

    iMSCP::File->new( filename => "$httpd->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'}/before/LetsEncrypt_Alias.conf" )->delFile() == 0 or die(
        getMessageByType( 'error', { remove => 1, amount => 1 } ) || 'Unknown error'
    );
}

=item _addCronjob( $cronjobId )

 Add the given plugin cronjob into i-MSCP core cron file

 Param string cronjobId Cronjob unique identifier
 Return void, die on failure

=cut

sub _addCronjob
{
    my ( $self, $cronjobId ) = @_;

    Servers::cron->factory()->addTask( {
        TASKID  => "Plugin::LetsEncrypt::${cronjobId}",
        MINUTE  => $self->{'config'}->{"cronjob_$cronjobId"}->{'minute'},
        HOUR    => $self->{'config'}->{"cronjob_$cronjobId"}->{'hour'},
        DAY     => $self->{'config'}->{"cronjob_$cronjobId"}->{'day'},
        MONTH   => $self->{'config'}->{"cronjob_$cronjobId"}->{'month'},
        DWEEK   => $self->{'config'}->{"cronjob_$cronjobId"}->{'dweek'},
        COMMAND => "/usr/bin/perl $main::imscpConfig{'PLUGINS_DIR'}/LetsEncrypt/cron/$cronjobId.pl > /dev/null 2>&1"
    } ) == 0 or die( getMessageByType( 'error', { remove => 1, amount => 1 } ) || 'Unknown error' );
}

=item _deleteCronjob( $cronjobId )

 Delete the given cronjob from the i-MSCP cron file

 Param string cronjobId Cronjob unique identifier
 Return void, die on failure

=cut

sub _deleteCronjob
{
    my ( undef, $cronjobId ) = @_;

    Servers::cron->factory()->deleteTask( { TASKID => "Plugin::LetsEncrypt::${cronjobId}" } ) == 0 or die(
        getMessageByType( 'error', { remove => 1, amount => 1 } ) || 'Unknown error'
    );
}

=item _readCertDataFromFiles( \%certData )

 Read SSL certificate data from file

 Param hashref \%certData SSL certificate data
 Return void, die on failure

=cut

sub _readCertDataFromFiles
{
    my ( $self, $certData ) = @_;

    my $certDirPath = "$self->{'config'}->{'letsencrypt_storage_path'}/live/$certData->{'domain_name'}";

    @{ $certData->{'files'} }{qw/ privkey cert chain /} = ( undef, undef, undef );
    for my $filename ( keys %{ $certData->{'files'} } ) {
        my $file = iMSCP::File->new( filename => "$certDirPath/$filename.pem" );
        $certData->{'files'}->{$filename} = $file->get();
        defined $certData->{'files'}->{$filename} or die( sprintf( "Couldn't read %s file: %s", $file->{'filename'},
            getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error'
        ));
    }
}

=item _handleCustomerSSLcertificate( \%certData )

 Handle customer SSL certificate

 Param hashref \%certData
 Return void, die on failure

=cut

sub _handleCustomerSSLcertificate
{
    my ( $self, $certData ) = @_;

    local $self->{'_dbh'}->{'RaiseError'} = 1;

    if ( $certData->{'letsencrypt_status'} ne 'todelete' ) {
        my ( $certId ) = $self->{'_dbh'}->selectrow_array(
            'SELECT cert_id FROM ssl_certs WHERE domain_id = ? AND domain_type = ?', undef, $certData->{'domain_id'}, $certData->{'domain_type'}
        );

        if ( !$certId ) {
            $self->{'_dbh'}->do(
                "INSERT INTO ssl_certs (domain_id, domain_type, private_key, certificate, ca_bundle, status) VALUES (?, ?, ?, ?, ?, 'toadd')",
                undef, $certData->{'domain_id'}, $certData->{'domain_type'}, $certData->{'files'}->{'privkey'}, $certData->{'files'}->{'cert'},
                $certData->{'files'}->{'chain'}
            );
            return;
        }

        $self->{'_dbh'}->do(
            "UPDATE ssl_certs SET private_key = ?, certificate = ?, ca_bundle = ?, status = 'tochange' WHERE cert_id = ?",
            undef, $certData->{'files'}->{'privkey'}, $certData->{'files'}->{'cert'}, $certData->{'files'}->{'chain'}, $certId
        );
        return;
    }

    $self->{'_dbh'}->do(
        "UPDATE ssl_certs SET status = 'todelete' WHERE domain_id = ? AND domain_type = ?",
        undef, $certData->{'domain_id'}, $certData->{'domain_type'}
    );
    $self->{'_dbh'}->do( 'DELETE FROM letsencrypt WHERE letsencrypt_id = ?', undef, $certData->{'letsencrypt_id'} );
}

=item _handleSystemSSLcertificate( \%certData )

 Handle system SSL certificate

 Param hashref \%certData
 Return void, die on failure

=cut

sub _handleSystemSSLcertificate
{
    my ( $self, $certData ) = @_;

    my $certPath = $main::imscpConfig{'CONF_DIR'} . '/' . ( $certData->{'domain_type'} eq 'control_panel'
        ? "$certData->{'domain_name'}.pem" : 'imscp_services.pem'
    );

    if ( $certData->{'letsencrypt_status'} ne 'todelete' ) {
        -f "${certPath}-core" || iMSCP::File->new( filename => $certPath )->copyFile( "${certPath}-core" ) == 0 or die(
            sprintf( "Couldn't backup original SSL certificate: %s", getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' )
        );

        my $file = iMSCP::File->new( filename => $certPath );
        $file->set( $certData->{'files'}->{'privkey'} . $certData->{'files'}->{'cert'} . $certData->{'files'}->{'chain'} );
        my $rs = $file->save();
        $rs ||= $file->owner( $main::imscpConfig{'ROOT_USER'}, $main::imscpConfig{'IMSCP_GROUP'} );
        $rs ||= $file->mode( 0640 );
        $rs == 0 or die( sprintf(
            "Couldn't create new SSL certificate: %s", getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error'
        ));
        $self->_scheduleServicesReload( $certData->{'domain_type'} );
        return;
    }

    if ( -f "${certPath}-core" ) {
        iMSCP::File->new( filename => "${certPath}-core" )->moveFile( $certPath ) == 0 or die(
            sprintf( "Couldn't restore default SSL certificate: %s", getMessageByType( 'error', { amount => 1, remove => 1 } ) || 'Unknown error' )
        );
        $self->_scheduleServicesReload( $certData->{'domain_type'} );
    }

    local $self->{'_dbh'}->{'RaiseError'} = 1;
    $self->{'_dbh'}->do( 'DELETE FROM letsencrypt WHERE letsencrypt_id = ?', undef, $certData->{'letsencrypt_id'} );
}

=item getCustomerDomainIdAndType( $domainName )

 Return unique identifier and type of the given customer domain name
 
 Param string $domainName Domain name
 Return hashref, die on failure

=cut

sub getCustomerDomainIdAndType
{
    my ( $self, $domainName ) = @_;

    local $self->{'_dbh'}->{'RaiseError'} = 1;
    $self->{'_dbh'}->selectrow_array(
        "
            SELECT domain_id, 'dmn' AS domain_type FROM domain WHERE domain_name = ?
            UNION ALL
            SELECT subdomain_id AS domain_id, 'sub' AS domain_type
            FROM subdomain
            JOIN domain USING(domain_id)
            WHERE CONCAT(subdomain_name, '.', domain_name) = ?
            UNION ALL
            SELECT alias_id AS domain_id, 'als' AS domain_type FROM domain_aliasses WHERE alias_name = ?
            UNION ALL
            SELECT subdomain_alias_id AS domain_id, 'alssub' AS domain_type
            FROM subdomain_alias
            JOIN domain_aliasses USING(alias_id)
            WHERE CONCAT(subdomain_alias_name, '.', alias_name) = ?
        ",
        undef, $domainName, $domainName, $domainName, $domainName
    );
}

=item issueCertificate( \%data )

 Issue (or renew) an SSL certificate

 Param hashref \%data Data SSL certificate data
 Return void, die on failure

=cut

sub _issueCertificate
{
    my ( $self, $data ) = @_;

    # It is important to always put the same name at first position because the
    # first entry is used by the Certbot client for the SSL lineage name.
    my @dnsNames = ( $data->{'domain_name'} );
    @dnsNames = uniq( @dnsNames, split /\n/, $data->{'letsencrypt_sans'} );
    @dnsNames <= 100 or die( sprintf( 'SSL certificate is limited up-to 100 DNS names. %d found.', @dnsNames ));

    my $requiredAction = $self->_getCertRequiredAction(
        "$self->{'config'}->{'letsencrypt_storage_path'}/live/$data->{'domain_name'}/cert.pem", @dnsNames
    );

    debug( sprintf( 'Required action: %s', $requiredAction ));

    # No action required (Certificate is still valid, identical DNS names).
    return if $requiredAction eq 'none';

    if ( $requiredAction eq 'issue' ) {
        # Make sure that there are no garbage left from a previous (failed)
        # Certbot client invocation
        $self->_deleteLineages( $data->{'domain_name'} );
    }

    local $ENV{'DEBIAN_FRONTEND'} = 'noninteractive';

    # https://acme-staging-v02.api.letsencrypt.org/directory
    # https://acme-v02.api.letsencrypt.org/directory

    # https://acme-staging.api.letsencrypt.org/directory
    # https://acme-v01.api.letsencrypt.org/directory

    # See https://certbot.eff.org/docs/using.html#managing-certificates
    my @certbotParams = (
        # Obtain or renew a certificate, but do not install it
        'certonly',
        # Certificate name to apply. This name is used by Certbot for
        # housekeeping and in file path. It doesn't affect the content
        # of the certificate itself. When creating a new certificate,
        # specify the new certificate name. It also cover case of both
        # expand and shrink in modification context.
        '--cert-name', $data->{'domain_name'},
        # Sorted, comma delimited list of the preferred challenge to use during
        # authorization with the most preferred challenge listed first. ACME
        # challenge are versionned, but if no version is specified, Certbot will
        # select the latest version automatically.
        '--preferred-challenges', 'http-01',
        # Email used for registration and recovery contact
        '--email', $main::imscpConfig{'DEFAULT_ADMIN_ADDRESS'},
        # Agree to the ACME Subscriber Agreement
        '--agree-tos',
        # Add a comment to default user agent string.
        '--user-agent-comment', "i-MSCP-LetsEncrypt/$self->{'info'}->{'version'}",
        # Silence all output except errors. Implies --non-interactive
        '--quiet',
        # Run without ever asking for user input. Implied by --quiet but added
        # for safety (case where option wouldn't be longer implied in a newer
        # Certbot version)
        '--non-interactive',
        # Working directory (already default but added for safety)
        '--work-dir', '/var/lib/letsencrypt',
        # Logs directory (already default but added for safety)
        '--logs-dir', '/var/log/letsencrypt',
        # Lower max log backups to 100 (default 1000 is far too high)
        '--max-log-backups', 100,

        # ACME Directory Resource URI
        # '--server', 'https://acme-v01.api.letsencrypt.org/directory', (current default for non staging env)
        # '--server', 'https://acme-staging.api.letsencrypt.org/directory'
        # '--server', 'https://acme-v02.api.letsencrypt.org/directory',
        # '--server', 'https://acme-staging-v02.api.letsencrypt.org/directory'

        # Obtain certificates by placing files in a webroot directory.
        '--webroot',
        '--webroot-path', "$main::imscpConfig{'PLUGINS_DIR'}/LetsEncrypt/acme",

        (
            # Tells Certbot to request a new certificate with the same domains as
            # an existing certificate. Each domain must be explicitely specified
            # via --domains option.
            $requiredAction eq 'renew' ? '--force-renewal' : ()
        ),
        (
            # Additional options as configured by system administrator in plugin
            # configuration file
            map { split /\s+/, $_, 2 } @{ $self->{'config'}->{'certbot_create_options'} }
        )
    );

    # Since v3.4.0: We now make use of --cert-name option only which cover both expand and shrink case.
    #elsif ( $requiredAction eq 'expand' ) {
    #    # Tells Certbot to update an existing certificate with a new certificate
    #    # that contains all of the old domains and one or more additional new
    #    # domains. Each domain must be explicitely specified via --domains
    #    # options.
    #    push @certbotParams, '--expand'
    #}

    push @certbotParams, '--domains', join( ',', @dnsNames );

    my ( $stdout, $stderr );
    $self->{'config'}->{'certbot_version'} eq 'develop'
        ? $self->_runCertbotFromDevelop( \@certbotParams )
        : execute( [ $self->{'config'}->{'certbot_path'}, @certbotParams ], \$stdout, \$stderr ) == 0 or die( $stderr || $stdout );
}

=item _revokeCertificate( \%certDaata )

 Revoke an SSL certificate
 
 Param hashref \%certData SSL certificate data
 Return void, die on failure

=cut

sub _revokeCertificate
{
    my ( $self, $certData ) = @_;

    if ( -f "$self->{'config'}->{'letsencrypt_storage_path'}/live/$certData->{'domain_name'}/cert.pem" ) {
        return if $self->_isSharedLineage( $certData->{'domain_name'} );

        local $ENV{'DEBIAN_FRONTEND'} = 'noninteractive';
        my @certbotParams = (
            # Revoke a certificate
            'revoke',
            # Email used for registration and recovery contact
            '--email', $main::imscpConfig{'DEFAULT_ADMIN_ADDRESS'},
            # Agree to the ACME Subscriber Agreement
            '--agree-tos',
            # Add a comment to default user agent string.
            '--user-agent-comment', "i-MSCP-LetsEncrypt/$self->{'info'}->{'version'}",
            # Silence all output except errors. Implies --non-interactive
            '--quiet',
            # Run without ever asking for user input. Implied by --quiet but added
            # for safety (case where option wouldn't be longer implied in a newer
            # Certbot version)
            '--non-interactive',
            # Working directory (already default but added for safety)
            '--work-dir', '/var/lib/letsencrypt',
            # Logs directory (already default but added for safety)
            '--logs-dir', '/var/log/letsencrypt',
            # Lower max log backups to 100 (default 1000 is far too high)
            '--max-log-backups', 100,

            # ACME Directory Resource URI
            # '--server', 'https://acme-v01.api.letsencrypt.org/directory',
            # '--server', 'https://acme-staging.api.letsencrypt.org/directory'
            # '--server', 'https://acme-v02.api.letsencrypt.org/directory',
            # '--server', 'https://acme-staging-v02.api.letsencrypt.org/directory'

            # Specify reason for revoking certificate.
            '--reason', 'unspecified',
            '--cert-path', "$self->{'config'}->{'letsencrypt_storage_path'}/live/$certData->{'domain_name'}/cert.pem",
            (
                # Additional options as configured by system administrator in plugin
                # configuration file
                map { split /\s+/, $_, 2 } @{ $self->{'config'}->{'certbot_revoke_options'} }
            )
        );
        eval {
            if ( $self->{'config'}->{'certbot_version'} eq 'develop' ) {
                $self->_runCertbotFromDevelop( \@certbotParams );
            } else {
                my $rs = execute( [ $self->{'config'}->{'certbot_path'}, @certbotParams ], \my $stdout, \my $stderr );
                $rs == 0 or die( $stderr || $stdout );
            }
        };
        $self->_getNewStatusFromErrorString( 'todelete', $@ ) eq 'todelete' or die if $@;
    }

    $self->_deleteLineages( $certData->{'domain_name'} );
}

=item _runCertbotFromDevelop( \@params = [] )

 Execute development version of certbot client

 Param arrayref \@params Certbot client parameters
 Return void, die on failure
 
=cut

sub _runCertbotFromDevelop
{
    my ( undef, $params ) = @_;
    $params //= [];

    my ( $stdout, $stderr );

    unless ( -d '/opt/imscp-certbot' ) {
        execute( 'git clone --depth=1 https://github.com/certbot/certbot /opt/imscp-certbot', \$stdout, \$stderr ) == 0 or die( $stderr || $stdout );
        debug( $stdout ) if $stdout;
        execute( '/opt/imscp-certbot/letsencrypt-auto --os-packages-only --non-interactive', \$stdout, \$stderr ) == 0 or die( $stderr || $stdout );
        debug( $stdout ) if $stdout;
        execute( 'cd /opt/imscp-certbot && sh /opt/imscp-certbot/tools/venv.sh', \$stdout, \$stderr ) == 0 or die( $stderr || $stdout );
        debug( $stdout ) if $stdout;
    }

    return unless @{ $params };

    execute( [ '/opt/imscp-certbot/venv/bin/certbot', @{ $params } ], \$stdout, \$stderr ) == 0 or die( $stdout || $stderr );
    debug( $stdout ) if $stdout;
}

=item _getCertRequiredAction( $certPath, @dnsNames )

 Determine required action for the given SSL certificate according its current state

 Param string $certPath Path of SSL certificate
 Param list @dnsNames List of DNS names for the SSL certificate
 Return string Required action (issue|expand|shrink|renew|none)), die on failure

=cut

sub _getCertRequiredAction
{
    my ( $self, $certPath, @dnsNames ) = @_;

    # SSL certificate is not existing.
    return 'issue' unless -f $certPath;

    my $x509 = $self->_decodePemCert( $certPath );
    my $issuerCommonName = $self->_getIssuerCommonName( $x509 );
    debug( "Issuer common name: $issuerCommonName" );

    if ( $issuerCommonName =~ /^fake/i && !grep (
        m%--(?:test-cert|staging|(?:server\s+\Qhttps://acme-staging\E))%, @{ $self->{'config'}->{'certbot_create_options'} }
    ) ) {
        debug( 'Switching from staging environment to production environment' );
        return 'issue';
    }

    my $expiryDate = $self->_getCertExpiryDate( $x509 );
    debug( sprintf( 'SSL certificate expiry date: %s GMT', scalar gmtime( $expiryDate )));

    # SSL certificate is expired.
    return 'renew' if $expiryDate <= time();

    my @oldDNSnames = $self->_getCertDNSnames( $x509 );
    @dnsNames = sort @dnsNames;

    debug( "Old SSL certificate DNS names: @oldDNSnames" );
    debug( "New Old SSL certificate DNS names: @dnsNames" );

    my $diff = Array::Diff->diff( \@oldDNSnames, \@dnsNames );

    # At least one DNS name has been added.
    return 'expand' if @{ $diff->added };
    # At least one DNS name has been removed.
    return 'shrink' if @{ $diff->deleted };
    # SSL certificate is near expire acccording current renewal policy
    return 'renew' if ( $expiryDate-$self->{'config'}->{'renewal_policy'} ) <= time();
    # There is no action needed.
    'none';
}

=item  _isSharedLineage( $domainName )

 Is the given lineage a shared lineage?

 Shared lineage in context of this plugin is when an SSL certificate is shared
 between several Let's Encrypt entities. This can be the case when both the
 control panel domain and server hostname match or when the control panel
 domain and/or server hostname are also added as customer domain or subdomain.

 Param string $domainName Domain name
 Return bool TRUE if the lineage matching the given domain name is shared, FALSE otherwise, die on failure

=cut

sub _isSharedLineage
{
    my ( $self, $domainName ) = @_;

    return 0 unless $domainName eq $main::imscpConfig{'SERVER_HOSTNAME'} || $domainName eq $main::imscpConfig{'BASE_SERVER_VHOST'};

    local $self->{'_dbh'}->{'RaiseError'} = 1;
    ( $self->{'_dbh'}->selectrow_array( 'SELECT COUNT(letsencrypt_id) FROM letsencrypt WHERE domain_name = ?', undef, $domainName ) ) > 1;
}

=item getEntitiesWithSharedLineage($lineageName)

 Return entities that share the given SSL lineage

 Param string $lineageName SSL lineage name
 Return hashref Entity data

=cut

sub getEntitiesWithSharedLineage
{
    my ( $self, $lineageName ) = @_;
    local $self->{'_dbh'}->{'RaiseError'} = 1;

    $self->{'_dbh'}->selectall_hashref(
        "SELECT * FROM letsencrypt WHERE domain_name = ? AND letsencrypt_status <> 'todelete'", 'domain_type', undef, $lineageName
    );
}

=item _deleteLineages( $domainName )

 Delete any lineage matching the given domain name

 Param string $domainName Domain name
 Return void, die on failure

=cut

sub _deleteLineages
{
    my ( $self, $domainName ) = @_;

    debug( sprintf( 'Deleting any SSL certificate lineage matching the %s domain name', $domainName ));

    my $storage = "$self->{'config'}->{'letsencrypt_storage_path'}/live";
    return unless -d $storage;

    for ( reverse sort grep ( /^\Q$domainName\E(?:-\d+)?$/, iMSCP::Dir->new( dirname => $storage )->getDirs()) ) {
        my $rs = execute( [ $self->{'config'}->{'certbot_path'}, 'delete', '--cert-name', $_ ], \my $stdout, \my $stderr );
        $rs == 0 || $self->_getNewStatusFromErrorString( 'todelete', $stderr || $stdout ) eq 'todelete' or die( $stderr || $stdout );
        iMSCP::Dir->new( dirname => "$storage/$_ " )->remove() if $rs;
    }
}

=item _getNewStatusFromErrorString( $status, $errStr )

 Get new status from the given error string

 Error strings were extracted from:
  - boulder at https://github.com/letsencrypt/boulder
  - certbot at https://github.com/certbot/certbot

 Only error strings bound to errors for which we want apply specific treatment
 are taken into consideration. Other error strings are left untouched and
 returned "AS THIS".
 
 We apply a specific treatment for the following errors:
  - Attempt to revoke an SSL certificate that is already revoked or not found
     We return the 'todelete' status. The backend can go ahead by removing the
     SSL certificate from the filesystem and database if any.
  -  Let's Encrypt rate limit hit, service outage...
     We return the 'pending' status which lead to queuing of the task for later
     processing.

 Param string $status Previous status
 Param string $errStr Error string
 Return string New status

=cut

sub _getNewStatusFromErrorString
{
    my ( undef, $status, $errStr ) = @_;

    return 'Unknown error' unless defined $errStr;
    return 'todelete' if $errStr =~ /certificate already revoked/i;
    return 'todelete' if $status eq 'todelete' && $errStr =~ /\Qno \E(?:\Qcertificate found\E|\Qexisting certificates found\E|\Qsuch certificate\E)/i;
    # Errors that lead to pending task such as a Let's Encrypt rate limit hit, service outage...
    return 'pending' if $errStr =~ /
        (?:\Qglobal certificate issuance limit reached\E|\Qthe server experienced an internal error\E|\Qtoo many \E(?:
            \Qcertificates already issued\E|\Qcurrently pending authorizations\E|\Qinvalid authorizations recently\E|\Qregistrations from this ip\E))
        /ix;
    #return 'pending' if $status eq 'todelete';
    # Error with no particular treatment
    $errStr;
}

=item _scheduleServicesReload( $target )

 Schedule reload/restart of services for the given target if required
 
 In most cases, a simple reload of the services is sufficient. Current
 workers/sessions still use oldest SSL certificates but this shouldn't
 be an issue because the SSL certificates are renewed many days before
 their expiry date.
 
 Param string $target Target (control_panel,services)
 Return void, die on failure

=cut

sub _scheduleServicesReload
{
    my ( undef, $target ) = @_;

    if ( $target eq 'control_panel' ) {
        Package::FrontEnd->getInstance()->{'reload'} = 1;
        Servers::httpd->factory()->{'restart'} = 1 if grep (/PanelRedirect/, iMSCP::Plugins->getInstance()->getList());
        return;
    }

    Servers::ftpd->factory()->{'reload'} = 1;
    Servers::mta->factory()->{'reload'} = 1;
    Servers::po->factory()->{'restart'} = 1;
}

=item _scheduleDomainChange( $domainId, $domainType )

 Schedule change of the given domain if required
 
 Param int $domainId Domain unique identifier
 Param string $domainType Domain type (dmn,als,sub,alssub)
 return void, die on failure

=cut

sub _scheduleDomainChange
{
    my ( $self, $domainId, $domainType ) = @_;

    my $sql;
    if ( $domainType eq 'dmn' ) {
        $sql = "UPDATE domain SET domain_status = 'tochange' WHERE domain_id = ? AND domain_status <> 'todelete' ";
    } elsif ( $domainType eq 'als' ) {
        $sql = "UPDATE domain_aliasses SET alias_status = 'tochange' WHERE alias_id = ? AND alias_status <> 'todelete'";
    } elsif ( $domainType eq 'sub' ) {
        $sql = "UPDATE subdomain SET subdomain_status = 'tochange' WHERE subdomain_id = ? AND subdomain_status <> 'todelete'";
    } else {
        $sql = "UPDATE subdomain_alias SET subdomain_alias_status = 'tochange' WHERE subdomain_alias_id = ? AND subdomain_alias_status <> 'todelete'";
    }

    local $self->{'_dbh'}->{'RaiseError'} = 1;
    $self->{'_dbh'}->do( $sql, undef, $domainId );
}

=item _getConvertASN1Object( [ $macro = 'Certificate' ] )

 Get a prepared Convert::ASN1 object for the given ASN.1 macro

 Param string $macro OPTIONAL Macro for which a Convert::ASN1 object must be returned (default: Certificate)
 Return Convert::ASN1, die on failure

=cut

sub _getConvertASN1Object
{
    my ( $self, $macro ) = @_;

    unless ( $self->{'_prepared_convert_asn1_object'} ) {
        my $convertASN1 = Convert::ASN1->new();
        $self->{'_prepared_convert_asn1_object'} = $convertASN1->prepare_file( "$main::imscpConfig{'PLUGINS_DIR'}/LetsEncrypt/resources/ASN.1/pkix" );
        $self->{'_prepared_convert_asn1_object'} or die( sprintf( "Couldn't prepare ConvertASN1 object: %s", $! ));
    }

    $self->{'_prepared_convert_asn1_object'}->find( $macro || 'Certificate' );
}

=item _decodePemCert( $certPath [, $forceDecode ] )

 Return a Convert::ASN1 object for the given PEM encoded SSL certificate

 See https://tools.ietf.org/html/rfc5280#section-4.1

 Param string $certPath Path to PEM encoded SSL certificiate
 Param bool $forceDecode Whether or not new decoding must be performed (case where $certpath has been already decoded)
 Return Convert::ASN1, die on failure

=cut

sub _decodePemCert
{
    my ( $self, $certPath, $forceDecode ) = @_;

    if ( !$self->{'_x509'}->{$certPath} || $forceDecode ) {
        open my $fh, '<', $certPath or die( sprintf( "Couldn't open %s file: %s", $certPath, $! ));
        my $derBlob = do {
            local $/;
            # Extract DER blob from PEM SSL certificate file
            decode_base64( <$fh> =~ s/^-.*?\n//gmr );
        };
        close( $fh );

        # Decode DER blob
        my $convertASN1 = $self->_getConvertASN1Object();
        $self->{'_x509'}->{$certPath} = $convertASN1->decode( $derBlob );
        !$convertASN1->error or die( sprintf( "Couldn't decode DER blob: %s", $convertASN1->error ));
    }

    $self->{'_x509'}->{$certPath};
}

=item _getIssuerCommonName( $x509 )

 Get SSL certificate issuer common name from the given Convert::ASN1 object

 See https://tools.ietf.org/html/rfc5280#section-4.1.2.4

 Param Convert::ASN1 $x509 Convert::ASN1 object describing a x509 SSL certificate
 Return string Issuer common name, die on failure

=cut

sub _getIssuerCommonName
{
    my ( undef, $x509 ) = @_;

    for my $relDistinguishedName ( @{ $x509->{'tbsCertificate'}->{'issuer'}->{'rdnSequence'} } ) {
        for my $attrTypeAndValue ( @{ $relDistinguishedName } ) {
            next unless $attrTypeAndValue->{'type'} eq '2.5.4.3';
            my @directoryString = keys( %{ $attrTypeAndValue->{'value'} } );
            return $attrTypeAndValue->{'value'}->{ $directoryString[0] };
        }
    }

    die( "Couldn't get SSL certificate Issuer common name" );
}

=item _getCertExpiryDate( $x509 )

 Get SSL certificate expiry date from the given Convert::ASN1 object

 See https://tools.ietf.org/html/rfc5280#section-4.1.2.5.1
 See https://tools.ietf.org/html/rfc5280#section-4.1.2.5.2

 Param Convert::ASN1 $x509 Convert::ASN1 object describing a x509 SSL certificate
 Return int SSL certificate expiry date, die on failure

=cut

sub _getCertExpiryDate
{
    my ( undef, $x509 ) = @_;

    my $expiryDate;
    if ( $x509->{'tbsCertificate'}->{'validity'}->{'notAfter'}->{'utcTime'} ) {
        $expiryDate = $x509->{'tbsCertificate'}->{'validity'}->{'notAfter'}->{'utcTime'};
    } elsif ( $x509->{'tbsCertificate'}->{'validity'}->{'notAfter'}->{'generalTime'} ) {
        $expiryDate = DateTime::Format::Strptime->new(
            on_error  => 'undef',
            pattern   => '%Y%m%d%H%M%S%Z',
            time_zone => 'GMT'
        )->parse_datetime( $x509->{'tbsCertificate'}->{'validity'}->{'notAfter'}->{'generalTime'} )->epoch();
    }
    $expiryDate or die( "Couldn't get SSL certificate expiry date" );
}

=item _getCertDNSnames( $x509 )

 Get DNS names from the given Convert::ASN1 object

 See https://tools.ietf.org/html/rfc5280#section-4.2.1.6

 Param Convert::ASN1 $x509 Convert::ASN1 object describing a x509 SSL certificate
 Return Sorted list of DNS names, die on failure

=cut

sub _getCertDNSnames
{
    my ( $self, $x509 ) = @_;

    my @dnsNames = ();
    for ( @{ $x509->{'tbsCertificate'}->{'extensions'} } ) {
        next unless $_->{'extnID'} eq '2.5.29.17'; # OID for SubjectAltName
        my $convertASN1 = $self->_getConvertASN1Object( 'SubjectAltName' );
        my $dnsNames = $convertASN1->decode( $_->{'extnValue'} );
        !$convertASN1->error or die( sprintf( "Couldn't decode DER blob: %s", $convertASN1->error ));
        ( @dnsNames = map { $_->{'dNSName'} // () } @{ $dnsNames } ) or die( "Couldn't find SubjectAltName (OID 2.5.29.17)" );
    }

    sort @dnsNames;
}

=iten _getVirtualEnvPaths

 Get Let's Encrypt old and new virtual environment paths

 We do not considere the $VENV_PATH environment variable here.

 @return List containing both the old path and new path

=cut

sub _getVirtualEnvPaths( )
{
    ( ( $ENV{'XDG_DATA_HOME'} || File::HomeDir->my_home . '/.local/share' ) . '/letsencrypt', '/opt/eff.org/certbot/venv' );
}

=back

=head1 EVENT LISTENERS

=over 4

=item onAfterCronInstall( \%eventManager )

 Register cron tasks on i-MSCP core upgrade/reconfiguration

 Param hashref $eventManager Event Manager instance
 Return int 0 on success, 1 on failure

=cut

sub onAfterCronInstall
{
    my ( $class, $eventManager ) = @_;

    eval {
        my $dbh = iMSCP::Database->factory()->getRawDb();
        local $dbh->{'RaiseError'} = 1;
        my $config = $dbh->selectrow_hashref( "SELECT plugin_config FROM plugin WHERE plugin_name = 'LetsEncrypt'" );
        $config or die( "Couldn't find LetsEncrypt plugin configuration in database" );
        $config = JSON->new()->decode( $config->{'plugin_config'} );
        my $self = $class->new(
            action       => 'setup',
            config       => $config,
            eventManager => $eventManager
        );
        $self->_addCronjob( 'pending' );
        $self->_addCronjob( 'renew' );
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    0;
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
