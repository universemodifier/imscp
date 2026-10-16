=head1 NAME

 Plugin::PhpSwitcher

=cut

# i-MSCP PhpSwitcher plugin
#
# @author Laurent Declercq <l.declercq@nuxwin.com>
# @copyright (C) 2014-2019 Laurent Declercq <l.declercq@nuxwin.com>
# @license i-MSCP License <https://www.i-mscp.net/license-agreement.html>

package Plugin::PhpSwitcher;

use strict;
use warnings;
use Cwd 'abs_path';
use File::Basename qw/ basename dirname fileparse /;
use File::Spec;
use iMSCP::Database;
use iMSCP::Debug qw/ debug error getMessageByType /;
use iMSCP::Dir;
use iMSCP::Execute qw/ execute escapeShell /;
use iMSCP::File;
use iMSCP::Service;
use iMSCP::TemplateParser qw/ getBloc process replaceBloc /;
use JSON 'decode_json';
use Package::FrontEnd;
use Scalar::Defer 'lazy';
use Servers::httpd;
use version;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 PhpSwitcher plugin backend.

=head1 CLASS METHODS

=over 4

=item registerSetupListeners( \%events )

 Register the setup event listeners

 Register an event listener that listens on the beforeSetupRestartServices event
 to schedule restart (or start) of the FPM instances managed by this plugin.

 Param iMSCP::EventManager \%events
 Return int 0 on success, 1 on failure

=cut

sub registerSetupListeners
{
    my ( $class, $events ) = @_;

    ( my $self = bless { eventManager => $events }, $class )->_init();

    return 0 unless $self->{'_isPhpFpm'};

    $self->{'eventManager'}->registerOne( 'beforeSetupRestartServices', sub {
        my ( $serviceStack ) = @_;

        eval {
            local $self->{'_dbh'}->{'RaiseError'} = 1;

            $self->{'config'} = decode_json( $self->{'_dbh'}->selectrow_hashref(
                "SELECT `plugin_config` FROM `plugin` WHERE `plugin_name` = 'PhpSwitcher'"
            )->{'plugin_config'} or die( 'PhpSwitcher plugin configuration not found in database.' ));

            my $phpVersions = $self->getPhpVersions();
            for my $phpVersion ( values %{ $phpVersions } ) {
                next if $phpVersion->{'version_status'} ne 'ok' || $phpVersion->{'version_is_default'};

                ( my $service = ( $self->{'config'}->{
                    $class->isPackagedPhpVersion( $phpVersion ) ? 'packaged' : 'compiled'
                }->{'php_fpm_service_name_pattern'} ) ) =~ s/%PHP_VERSION%/$phpVersion->{'version_name'}/g;

                next unless $self->{'_serviceManager'}->hasService( $service );

                push @{ $serviceStack }, [
                    sub {
                        eval {
                            $self->{'_serviceManager'}->enable( $service );
                            $self->{'_serviceManager'}->restart( $service );
                        };
                        if ( $@ ) {
                            error( $@ );
                            return 1;
                        }

                        0;
                    },
                    "$service service"
                ];
            }
        };
        if ( $@ ) {
            error( $@ );
            return 1;
        }

        0;
    } );
}

=cut

=back

=head1 PUBLIC METHODS

=over 4

=item install( )

 Installation tasks

 Return int 0 on success, 1 on failure

=cut

sub install
{
    # Packaged PHP versions are already provided by the distribution.
    # The compiler toolchain is installed only when a build is requested.
    0;
}

=item uninstall( )

 Uninstallation tasks

 Return int 0 on success, 1 on failure

=cut

sub uninstall
{
    my ( $self ) = @_;

    eval { $self->_uninstallDistributionPackages(); };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    0;
}

=item update( $fromVersion )

 Update tasks

 Param string $fromVersion Version from which the plugin is being updated
 Return int 0 on success, other on failure

=cut

sub update
{
    my ( $self, $fromVersion ) = @_;

    my $rs = eval {
        local $self->{'_dbh'}->{'RaiseError'} = 1;

        $self->_installDistributionPackages();

        $fromVersion = version->parse( $fromVersion );

        if ( $fromVersion < version->parse( '2.2.0' ) && -f "$::imscpConfig{'CONF_DIR'}/listeners.d/01_phpswitcher_setup.pl" ) {
            my $rs = iMSCP::File->new(
                filename => $::imscpConfig{'CONF_DIR'} . '/listeners.d/01_phpswitcher_setup.pl'
            )->delFile();
            return $rs if $rs;
        }

        if ( $fromVersion < version->parse( '2.2.1' ) ) {
            my $phpVersions = $self->getPhpVersions();
            for my $phpVersion ( values %{ $phpVersions } ) {
                next if $phpVersion->{'version_is_default'} || $self->isPackagedPhpVersion( $phpVersion );

                my ( $basename, $path ) = fileparse( $phpVersion->{'version_fpm_binary_path'} );

                next unless $basename =~ s/^psw-(.*)/psw$1/;

                $path = File::Spec->canonpath( "$path/$basename" );
                $self->{'_dbh'}->do(
                    "
                        UPDATE `$self->{'config'}->{'database'}->{'php_version_table'}`
                        SET `version_fpm_binary_path` = ?
                        WHERE `version_id` = ?
                    ",
                    undef, $path, $phpVersion->{'version_id'}
                );

                if ( -f $phpVersion->{'version_fpm_binary_path'} ) {
                    my $rs = iMSCP::File->new( filename => $phpVersion->{'version_fpm_binary_path'} )->moveFile( $path );
                    return $rs if $rs;
                }

                $phpVersion->{'version_fpm_binary_path'} = $path;
            }
        }

        if ( $fromVersion < version->parse( '2.2.3' ) ) {
            $self->{'_dbh'}->do(
                "
                    DELETE FROM `$self->{'config'}->{'database'}->{'domain_php_version_table'}`
                    WHERE `domain_name` NOT IN(
                        SELECT CONCAT(`subdomain_alias_name`, '.', `alias_name`)
                        FROM `subdomain_alias`
                        JOIN `domain_aliasses` USING(`alias_id`)
                    )
                "
            );
        }

        if ( $fromVersion < version->parse( '3.0.0' ) ) {
            for my $file ( glob( $self->{'config_prev'}->{'compiled_php_vesion'}->{ 'php_fpm_lib_dir' } . '/psw*checkonf' ) ) {
                my $rs = iMSCP::File->new( filename => $file )->delFile();
                return $rs if $rs;
            }
        }

        if ( $fromVersion < version->parse( '5.0.0' ) ) {
            # In previous versions, some people patched the backend to allow
            # registration of packaged PHP versions. The problem is that the
            # configuration files were generated without any distinction, as if
            # the packaged PHP versions were compiled PHP versions. Packaged PHP
            # versions come with their own configuration files which must not be
            # managed by the plugin. To solve this problem (removal of orphaned
            # configuration files), we deconfigure all PHP versions. This
            # shouldn't be a problem as these will be generated again when the
            # plugin will get re-activated.
            for my $phpVersion ( qw/ 5.6 7.0 7.1 7.2 7.3 7.4 / ) {
                $self->_deconfigureFpm( {
                    version_name                    => $phpVersion,
                    version_version                 => $phpVersion . '.0', # no relevant
                    version_is_packaged             => 0,
                    version_is_default              => 0,
                    version_fpm_pool_directory_path => '/tmp/.psw_dummy' # no relevant
                } );
            }

            # Since version 5.0.0, registration of a PHP version matching the
            # default PHP version is not longer allowed. If that was the case,
            # we schedule it deletion.
            my $phpVersions = $self->getPhpVersions();
            for my $phpVersion ( values %{ $phpVersions } ) {
                next unless index( $phpVersion->{'version_version'}, $self->{'_httpd'}->{'phpConfig'}->{'PHP_VERSION'} ) == 0;
                $self->{'_dbh'}->do(
                    "
                        UPDATE `$self->{'config'}->{'database'}->{'php_version_table'}`
                        SET `version_status` = 'todelete'
                        WHERE `version_id` = ?
                    ",
                    undef,
                    $phpVersion->{'version_id'}
                );
                $phpVersion->{'version_status'} = 'todelete';
            }
        }

        0;
    };
    if ( $@ ) {
        error( $@ );
        $rs = 1;
    }

    $rs;
}

=item enable( )

 Activation tasks

 Return int 0 on success, other on failure

=cut

sub enable
{
    my ( $self ) = @_;

    my $rs = eval {
        my $rs = iMSCP::File->new( filename => $self->{'_thisPluginDir'} . '/listeners.d/50_psw_dpkg_post_invoke_tasks.pl' )->copyFile(
            "$::imscpConfig{'CONF_DIR'}/listeners.d/", { preserve => 'no' }
        );
        return $rs if $rs;

        my $file = iMSCP::File->new( filename => $::imscpConfig{'CONF_DIR'} . '/listeners.d/50_psw_dpkg_post_invoke_tasks.pl' );
        $rs = $file->owner( $::imscpConfig{'ROOT_USER'}, $::imscpConfig{'IMSCP_GROUP'} );
        $rs ||= $file->mode( 0640 );
        return $rs if $rs;

        if ( $self->{'_isPhpFpm'} ) {
            for my $dir ( qw/
                php_fpm_lib_dir php_fpm_log_dir php_fpm_run_dir sys_logrotate_dir sys_tmpfiles_dir sys_systemd_unit_dir
                sys_sysvinit_dir
            / ) {
                iMSCP::Dir->new( dirname => $self->{'config'}->{'compiled'}->{$dir} )->make( {
                    user  => $::imscpConfig{'ROOT_USER'},
                    group => $::imscpConfig{'ROOT_GROUP'},
                    mode  => 0755
                } );
            }

            $self->_setupNginxMainConfigForPhpInfo( 'configure' );
        }

        $self->_initDatabase();

        my $phpVersions = $self->getPhpVersions( 1 );
        for my $phpVersion ( values %{ $phpVersions } ) {
            next if grep ( $_ eq $phpVersion->{'version_status'}, qw/ todelete disabled / );
            $phpVersion->{'version_status'} = 'toenable';
        }

        $rs = $self->run();

        if ( $rs == 0 && $self->{'_needNginxReload'} && !$self->{'_isSetupContext'} ) {
            $rs = Package::FrontEnd->getInstance()->reloadNginx();
        }

        $rs;
    };
    if ( $@ ) {
        error( $@ );
        $rs = 1;
    }

    $rs;
}

=item disable( )

 Deactivation tasks

 Return int 0 on success, other on failure

=cut

sub disable
{
    my ( $self ) = @_;

    my $rs = eval {
        local $self->{'_dbh'}->{'RaiseError'} = 1;

        if ( $self->{'action'} eq 'change' && $self->{'_httpd'}->{'phpConfig'}->{'PHP_CONFIG_LEVEL'} =~ /^per_(?:user|domain)$/ ) {
            if ( $self->{'_httpd'}->{'phpConfig'}->{'PHP_CONFIG_LEVEL'} eq 'per_user' ) {
                $self->{'_dbh'}->do(
                    "DELETE FROM `$self->{'config'}->{'database'}->{'domain_php_version_table'}` WHERE `domain_type` <> 'dmn'"
                );
            } else {
                $self->{'_dbh'}->do(
                    "DELETE FROM `$self->{'config'}->{'database'}->{'domain_php_version_table'}` WHERE `domain_type` NOT IN ('dmn', 'als')"
                );
            }
        }

        my $phpVersions = $self->getPhpVersions();
        for my $phpVersion ( values %{ $phpVersions } ) {
            next if $phpVersion->{'version_status'} eq 'disabled';
            $phpVersion->{'version_status'} = 'todisable';
        }

        my $rs = $self->run();
        return $rs if $rs;

        $self->_setupNginxMainConfigForPhpInfo( 'deconfigure' );

        for my $dir ( qw/ php_fpm_lib_dir php_fpm_log_dir php_fpm_run_dir / ) {
            iMSCP::Dir->new( dirname => $self->{'config_prev'}->{'compiled'}->{$dir} )->remove();
        }

        iMSCP::Dir->new( dirname => "$self->{'_thisPluginDir'}/phpinfo" )->remove();

        if ( -f $::imscpConfig{'CONF_DIR'} . '/listeners.d/50_psw_dpkg_post_invoke_tasks.pl' ) {
            $rs = iMSCP::File->new( filename => $::imscpConfig{'CONF_DIR'} . '/listeners.d/50_psw_dpkg_post_invoke_tasks.pl' )->delFile();
            return $rs if $rs;
        }

        if ( $self->{'_needNginxReload'} && $self->{'action'} eq 'disable' && !$self->{'_isSetupContext'} ) {
            $rs = Package::FrontEnd->getInstance()->reloadNginx();
            return $rs if $rs;
        }

        0;
    };
    if ( $@ ) {
        error( $@ );
        $rs = 1;
    }

    $rs;
}

=item run( )

 Process plugin tasks

 Return int 0 on success, 1 on failure

=cut

sub run
{
    my ( $self ) = @_;

    eval {
        $self->_registerEventListeners();

        local $self->{'_dbh'}->{'RaiseError'} = 1;

        my $phpVersions = $self->getPhpVersions();
        for my $phpVersion ( sort { $a->{'version_name'} cmp $b->{'version_name'} } values( %{ $phpVersions } ) ) {
            next if $self->{'action'} eq 'run' && $phpVersion->{'version_status'} eq 'ok';

            eval {
                if ( grep ( $_ eq $phpVersion->{'version_status'}, qw/ toadd tochange toenable / ) ) {
                    my ( $major, $minor, $tiny, $stage ) =
                        $self->_checkPhpVersion( $phpVersion );

                    (
                        $phpVersion->{'version_version'}, $phpVersion->{'version_name'},
                        $phpVersion->{'version_major'}, $phpVersion->{'version_minor'},
                        $phpVersion->{'version_tiny'}, $phpVersion->{'version_stage'}
                    ) = (
                        "$major.$minor.$tiny" . $stage, "$major.$minor",
                        $major, $minor,
                        $tiny, $stage
                    );

                    $phpVersion->{'version_is_default'} = $phpVersion->{'version_name'} eq $self->_getDefaultPhpVersion()->{'version_name'} ? 1 : 0;

                    unless ( $self->{'noFullPhpVersionsReconfiguration'} ) {
                        $self->_deconfigureFpm( $phpVersion );
                        $self->_configureFpm( $phpVersion ) if $self->{'_isPhpFpm'};
                        $self->_configurePhpVersionInfo( $phpVersion );
                    }

                    $self->{'_dbh'}->begin_work();
                    $self->{'_dbh'}->do(
                        "
                            UPDATE `$self->{'config'}->{'database'}->{'php_version_table'}`
                            SET `version_version` = ?,
                                `version_name` = ?,
                                `version_is_packaged` = ?,
                                `version_is_default` = ?,
                                `version_status` = 'ok'
                            WHERE `version_id` = ?
                        ",
                        undef,
                        $phpVersion->{'version_version'},
                        $phpVersion->{'version_name'},
                        $self->isPackagedPhpVersion( $phpVersion ),
                        $phpVersion->{'version_is_default'} // 0,
                        $phpVersion->{'version_id'}
                    );

                    if ( !$self->{'_isSetupContext'} && $phpVersion->{'version_status'} ne 'toadd' ) {
                        $self->_scheduleDomainsChange( $phpVersion->{'version_id'} );
                    }

                    $self->{'_dbh'}->commit();
                    $phpVersion->{'version_status'} = 'ok';
                } elsif ( $phpVersion->{'version_status'} eq 'todisable' ) {
                    $self->_deconfigurePhpVersionInfo( $phpVersion );
                    $self->_deconfigureFpm( $phpVersion );

                    # Must be done prior SQL statements execution as the event
                    # listeners must be aware of change in any case
                    $phpVersion->{'version_status'} = 'disabled';
                    undef $self->{'_domainPhpVersionMap'};

                    $self->{'_dbh'}->begin_work();

                    if ( !$self->{'_isSetupContext'} ) {
                        $self->_scheduleDomainsChange( $phpVersion->{'version_id'} );
                    }

                    if ( $self->{'action'} eq 'run' ) {
                        $self->{'_dbh'}->do(
                            "
                                UPDATE `$self->{'config'}->{'database'}->{'php_version_table'}`
                                SET `version_status` = 'disabled'
                                WHERE `version_id` = ?
                            ",
                            undef,
                            $phpVersion->{'version_id'}
                        );
                    }

                    $self->{'_dbh'}->commit();
                } elsif ( $phpVersion->{'version_status'} eq 'todelete' ) {
                    $self->_deconfigurePhpVersionInfo( $phpVersion );
                    $self->_deconfigureFpm( $phpVersion );

                    # Must be done prior SQL statements execution as the event
                    # listeners must be aware of change in any case
                    delete $phpVersions->{$phpVersion->{'version_id'}};
                    undef $self->{'_domainPhpVersionMap'};

                    $self->{'_dbh'}->begin_work();

                    # Need to be processed first, else data won't be longer
                    # available at processing time...
                    unless ( $self->{'_isSetupContext'} ) {
                        $self->_scheduleDomainsChange( $phpVersion->{'version_id'} );
                    }

                    $self->{'_dbh'}->do(
                        "DELETE FROM `$self->{'config'}->{'database'}->{'php_version_table'}` WHERE `version_id` = ?",
                        undef,
                        $phpVersion->{'version_id'}
                    );

                    $self->{'_dbh'}->commit();
                } elsif ( $phpVersion->{'version_status'} eq 'phpinfo' ) {
                    $self->_configurePhpVersionInfo( $phpVersion );

                    $self->{'_dbh'}->do(
                        "
                            UPDATE `$self->{'config'}->{'database'}->{'php_version_table'}`
                            SET `version_status` = 'ok'
                            WHERE `version_id` = ?
                        ",
                        undef,
                        $phpVersion->{'version_id'}
                    ) if $self->{'action'} eq 'run';

                    $phpVersion->{'version_status'} = 'ok';
                }
            };
            if ( $@ ) {
                $self->{'_dbh'}->rollback() if $self->{'_dbh'}->{'BegunWork'};
                $self->{'_dbh'}->do(
                    "
                        UPDATE `$self->{'config'}->{'database'}->{'php_version_table'}`
                        SET `version_status` = ?
                        WHERE `version_id` = ?
                    ",
                    undef,
                    $@,
                    $phpVersion->{'version_id'}
                );
            }
        }

        if ( $self->{'_needNginxReload'} && !$self->{'_isSetupContext'} && $self->{'action'} eq 'run' ) {
            Package::FrontEnd->getInstance()->reloadNginx() == 0 or die( getMessageByType( 'error', { amount => 1, remove => 1 } ));
        }
    };
    if ( $@ ) {
        $self->{'FORCE_RETVAL'} = 1;
        error( $@ );
        return 1;
    }

    0;
}

=item getPhpVersions( [ $forceReload = FALSE ] )

 Get PHP versions

 Param bool $forceReload Whether PHP version data must be reloaded from database
 Return hashref, die on failure

=cut

sub getPhpVersions
{
    my ( $self, $forceReload ) = @_;

    $self->{'_phpVersions'} = undef if $forceReload;
    $self->{'_phpVersions'} //= do {
        local $self->{'_dbh'}->{'RaiseError'} = 1;
        my $phpVersions = $self->{'_dbh'}->selectall_hashref(
            "SELECT * FROM `$self->{'config'}->{'database'}->{'php_version_table'}`", 'version_id'
        );

        for my $phpVersion ( values %{ $phpVersions } ) {
            next unless length $phpVersion->{'version_version'};
            (
                $phpVersion->{'version_major'}, $phpVersion->{'version_minor'},
                $phpVersion->{'version_tiny'}, $phpVersion->{'version_stage'},
                $phpVersion->{'version_name'}
            ) = (
                $phpVersion->{'version_version'} =~ /^(\d+)\.(\d+)\.(\d+)(.*)/,
                "$1.$2"
            );
        }

        $phpVersions;
    };
}

=item isPackagedPhpVersion( \%phpVersion )

 Is the given PHP version a packaged PHP version?

 Param hashref \%phpVersion PHP version data
 Return bool TRUE if the given PHP version look like a packaged PHP version,
             FALSE otherwise

=cut

sub isPackagedPhpVersion
{
    my ( undef, $phpVersion ) = @_;

    $phpVersion->{'version_is_packaged'} //= do {
        my @cmdArgv;

        for my $filePath ( $phpVersion->{'version_cgi_binary_path'}, $phpVersion->{'version_fpm_binary_path'}, '/usr/share/php/PEAR.php' ) {
            push @cmdArgv, escapeShell( $filePath );
        }

        execute( "/usr/bin/dpkg-query -S @cmdArgv >/dev/null 2>&1" ) == 0;
    };
}

=back

=head1 EVENT LISTENERS

=over 4

=item _overrideHttpFcgidServerSettings( \%moduleData )

 Event listener that listens on the beforeHttpdAddCfg to override the Fcgid
 httpd server settings

 Param hashref \%moduleData Module data
 Return int 0 on success, 1 on failure

=cut

sub _overrideHttpFcgidServerSettings
{
    my ( $self, $moduleData ) = @_;

    return 0 unless $moduleData->{'FORWARD'} eq 'no' && $moduleData->{'PHP_SUPPORT'} eq 'yes';

    eval {
        my $domain = ( $self->{'_httpd'}->{'phpConfig'}->{'PHP_CONFIG_LEVEL'}
            eq 'per_user'
            ? $moduleData->{'ROOT_DOMAIN_NAME'}
            : ( $self->{'_httpd'}->{'phpConfig'}->{'PHP_CONFIG_LEVEL'}
            eq 'per_domain'
            ? $moduleData->{'PARENT_DOMAIN_NAME'} : $moduleData->{'DOMAIN_NAME'}
        ) );

        defined( my $phpVersion = $self->_getDomainPhpVersion( $domain, 'ok' ) ) or die( sprintf(
            "Couldn't find PHP version for the %s domain", $domain
        ));

        debug( sprintf( 'Setting PEAR directory for %s: %s', $domain, $phpVersion->{'version_pear_directory_path'} ), ( caller( 1 ) )[3] );

        $moduleData->{'PEAR_DIR'} = $phpVersion->{'version_pear_directory_path'};

        local $self->{'_phpConfigObject'}->{'temporary'} = 1;

        debug( sprintf( 'Setting PHP version for %s: %s', $domain, $phpVersion->{'version_version'} ), ( caller( 1 ) )[3] );

        $self->{'_httpd'}->{'phpConfig'}->{'PHP_VERSION'} = $phpVersion->{'version_name'};

        debug( sprintf( "Setting PHP FastCGI binary path for %s: %s", $domain, $phpVersion->{'version_cgi_binary_path'} ), ( caller( 1 ) )[3] );

        $self->{'_httpd'}->{'phpConfig'}->{'PHP_FCGI_BIN_PATH'} = $phpVersion->{'version_cgi_binary_path'};
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    0;
}

=item _overrideHttpFpmServerSettings( \%moduleData )

 Event listener that listens on the beforeHttpdAddCfg event to override the FPM
 httpd server settings

 Param hashref \%moduleData Module data
 Return int 0 on success, 1 on failure

=cut

sub _overrideHttpFpmServerSettings
{
    my ( $self, $moduleData ) = @_;

    return 0 unless $moduleData->{'FORWARD'} eq 'no' && $moduleData->{'PHP_SUPPORT'} eq 'yes';

    eval {
        my $domain = ( $self->{'_httpd'}->{'phpConfig'}->{'PHP_CONFIG_LEVEL'}
            eq 'per_user'
            ? $moduleData->{'ROOT_DOMAIN_NAME'}
            : ( $self->{'_httpd'}->{'phpConfig'}->{'PHP_CONFIG_LEVEL'}
            eq 'per_domain'
            ? $moduleData->{'PARENT_DOMAIN_NAME'} : $moduleData->{'DOMAIN_NAME'}
        ) );

        defined( my $phpVersion = $self->_getDomainPhpVersion( $domain, 'ok' ) ) or die( sprintf(
            "Couldn't find PHP version for the %s domain.", $domain
        ));

        debug( sprintf( 'Setting PEAR directory for %s: %s', $domain, $phpVersion->{'version_pear_directory_path'} ), ( caller( 1 ) )[3] );

        $moduleData->{'PEAR_DIR'} = $phpVersion->{'version_pear_directory_path'};

        local $self->{'_phpConfigObject'}->{'temporary'} = 1;

        debug( sprintf( 'Setting PHP-FPM pool directory for %s: %s', $domain, $phpVersion->{'version_fpm_pool_directory_path'} ), ( caller( 1 ) )[3] );

        $self->{'_httpd'}->{'phpConfig'}->{'PHP_FPM_POOL_DIR_PATH'} = $phpVersion->{'version_fpm_pool_directory_path'};

        debug( sprintf( 'Setting PHP version for %s: %s', $domain, $phpVersion->{'version_version'} ), ( caller( 1 ) )[3] );

        $self->{'_httpd'}->{'phpConfig'}->{'PHP_VERSION'} = $phpVersion->{'version_name'};
        $self->{'_fpmInstancesToReload'}->{$phpVersion->{'version_id'}} = 1;
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    0;
}

=item _overridePhpTemplates( $serviceName, $tplName, \$tplContent, \%moduleData )

 Event listener that listens on the onLoadTemplate event to overrides the PHP
 templates

 Param string $serviceName Service name
 Param string $tplName Template file name
 Param string \$tplContent Template content
 Param hashref \%data Module data
 Return int 0 on success, other on failure

=cut

sub _overridePhpTemplates
{
    my ( $self, $serviceName, $tplName, $tplContent, $moduleData ) = @_;

    return 0 unless $serviceName =~ /^apache_(?:fcgid|php_fpm)$/ && $tplName =~ /^(php\.ini|pool\.conf)$/ && $moduleData->{'FORWARD'} eq 'no' && $moduleData->{'PHP_SUPPORT'} eq 'yes';

    my $rs = eval {
        my $domain = ( $self->{'_httpd'}->{'phpConfig'}->{'PHP_CONFIG_LEVEL'}
            eq 'per_user'
            ? $moduleData->{'ROOT_DOMAIN_NAME'}
            : ( $self->{'_httpd'}->{'phpConfig'}->{'PHP_CONFIG_LEVEL'}
            eq 'per_domain'
            ? $moduleData->{'PARENT_DOMAIN_NAME'} : $moduleData->{'DOMAIN_NAME'}
        ) );

        defined( my $phpVersion = $self->_getDomainPhpVersion( $domain, 'ok' ) ) or die( sprintf(
            "Couldn't find PHP version for the %s domain.", $domain
        ));

        if ( $tplName eq 'php.ini' ) {
            my $rs = $self->{'eventManager'}->trigger( 'onLoadTemplate', 'PhpSwitcher', "$phpVersion->{'version_name'}.ini", \my $cfgTpl, $moduleData );
            return $rs if $rs;

            unless ( defined $cfgTpl ) {
                return 1 unless defined( $cfgTpl = iMSCP::File->new( filename => "$self->{'_thisPluginDir'}/PhpCompiler" . "/templates/php/$phpVersion->{'version_name'}.ini" )->get() );
            }

            ${ $tplContent } = $cfgTpl;
            return 0;
        }

        my $rs = $self->{'eventManager'}->trigger( 'onLoadTemplate', 'PhpSwitcher', 'php-fpm.pool', \my $cfgTpl, $moduleData );
        return $rs if $rs;

        unless ( defined $cfgTpl ) {
            return 1 unless defined( $cfgTpl = iMSCP::File->new( filename => $self->{'_thisPluginDir'} . "/PhpCompiler/templates/php/fpm/php-fpm.pool" )->get() );
        }

        ${ $tplContent } = $cfgTpl;
        0;
    };
    if ( $@ ) {
        error( $@ );
        $rs = 1;
    }

    $rs;
}

=item _overrideFpmUdsPath( $serviceName, $tplName, \$tplContent, \%moduleData )

 Event listener that listens on the beforeHttpdBuildConf event to override the
 FPM FastCGI UDS path

 Param string $serviceName Service name
 Param string $tplName Template file name
 Param string \$tplContent Template content
 Param hashref \%moduleData Module data
 Return int 0 on success, 1 on failure

=cut

sub _overrideFpmUdsPath
{
    my ( $self, undef, $tplName, $moduleData ) = @_;

    return 0 unless $tplName =~ /^(?:domain(?:_ssl)?\.tpl|pool\.conf)$/ && $moduleData->{'FORWARD'} eq 'no' && $moduleData->{'PHP_SUPPORT'} eq 'yes';

    eval {
        my $domain = ( $self->{'_httpd'}->{'phpConfig'}->{'PHP_CONFIG_LEVEL'}
            eq 'per_user'
            ? $moduleData->{'ROOT_DOMAIN_NAME'}
            : ( $self->{'_httpd'}->{'phpConfig'}->{'PHP_CONFIG_LEVEL'}
            eq 'per_domain'
            ? $moduleData->{'PARENT_DOMAIN_NAME'} : $moduleData->{'DOMAIN_NAME'}
        ) );

        defined( my $phpVersion = $self->_getDomainPhpVersion( $domain, 'ok' ) ) or die( sprintf(
            "Couldn't find PHP version for the %s domain.", $domain
        ));

        my $config = $self->{'config'}->{$self->isPackagedPhpVersion( $phpVersion ) ? 'packaged' : 'compiled'};
        ( my $sockPath = "$config->{'php_fpm_run_dir'}/$config->{'php_fpm_uds_path_pattern'}" ) =~ s/%(PHP_VERSION|DOMAIN)%/
            { PHP_VERSION => $phpVersion->{'version_name'}, DOMAIN => $domain }->{$1}
        /ge;

        debug( sprintf( 'Setting FPM UDS path for %s: %s', $domain, $sockPath ), ( caller( 1 ) )[3] );

        if ( $tplName eq 'pool.conf' ) {
            $self->{'_httpd'}->setData( { PHP_FPM_LISTEN_ENDPOINT => $sockPath } );
            return;
        }

        $self->{'_httpd'}->setData( { PROXY_FCGI_PATH => "unix:$sockPath|" } );
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    0;
}

=item _deleteObsoleteFpmConfig( \%moduleData )

 Event listener that listens to the afterHttpdBuildPhpConf, afterHttpdDisableDmn,
 and afterHttpdDelDmn events to delete the obsolete FPM pool configuration files

 Param hashref \%moduleData Module data
 Return int 0 on success, other on failure

=cut

sub _deleteObsoleteFpmConfig
{
    my ( $self, $moduleData ) = @_;

    my $rs = eval {
        my $defaultPhpVersion = $self->_getDefaultPhpVersion();
        my $phpVersions = $self->getPhpVersions();
        my $domainPhpVersion = $self->_getDomainPhpVersion(
            $moduleData->{'DOMAIN_NAME'}, 'ok'
        );

        for my $phpVersion ( values %{ $phpVersions } ) {
            next if ( !defined $domainPhpVersion
                && $defaultPhpVersion->{'version_id'} eq $phpVersion->{'version_id'}
            ) || $phpVersion->{'version_id'} eq $domainPhpVersion->{'version_id'};

            next unless -f $phpVersion->{'version_fpm_pool_directory_path'} . "/$moduleData->{'DOMAIN_NAME'}.conf";

            my $rs = iMSCP::File->new( filename => $phpVersion->{'version_fpm_pool_directory_path'} . "/$moduleData->{'DOMAIN_NAME'}.conf" )->delFile();
            return $rs if $rs;

            unless ( $self->{'_isSetupContext'} ) {
                my $config = $self->{'config'}->{$self->isPackagedPhpVersion( $phpVersion ) ? 'packaged' : 'compiled'};
                ( my $service = $config->{'php_fpm_service_name_pattern'} ) =~ s/%PHP_VERSION%/$phpVersion->{'version_name'}/g;
                $self->{'_serviceManager'}->reload( $service );
            }
        }
    };
    if ( $@ ) {
        error( $@ );
        $rs = 1;
    }

    $rs;
}

=item resetHttpServerSettings( )

 Event listener that listens the beforeHttpdStart, beforeHttpdRestart, and
 beforeHttpdStop events to reset Httpd server settings

 Return int 0 on success, other on failure

=cut

sub resetHttpServerSettings
{
    my ( $self ) = @_;

    eval {
        local $self->{'_phpConfigObject'}->{'temporary'} = 1;

        my $defaultPhpVersion = $self->_getDefaultPhpVersion();

        debug( sprintf( 'Resetting PHP version: %s', $defaultPhpVersion->{'version_version'} ));
        $self->{'_httpd'}->{'phpConfig'}->{'PHP_VERSION'} = $defaultPhpVersion->{'version_name'};

        if ( $self->{'_isPhpFpm'} ) {
            debug( sprintf( 'Resetting PHP-FPM pool directory: %s', $defaultPhpVersion->{'version_fpm_pool_directory_path'} ));
            $self->{'_httpd'}->{'phpConfig'}->{'PHP_FPM_POOL_DIR_PATH'} = $defaultPhpVersion->{'version_fpm_pool_directory_path'};
            return;
        }

        debug( sprintf( 'Resetting PHP-FCGI binary path: %s', $defaultPhpVersion->{'version_cgi_binary_path'} ));
        $self->{'_httpd'}->{'phpConfig'}->{'PHP_FCGI_BIN_PATH'} = $defaultPhpVersion->{'version_cgi_binary_path'};
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    0;
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init( )

 Initialize instance

 Return Plugin::PhpSwitcher, die on failure

=cut

sub _init
{
    my ( $self ) = @_;

    # Flags
    $self->{'noFullPhpVersionsReconfiguration'} //= 0;

    $self->{'_thisPluginDir'} = lazy { abs_path( dirname( __FILE__ ) . '/..' ); };
    $self->{'_dbh'} = lazy { iMSCP::Database->factory()->getRawDb(); };
    $self->{'_httpd'} = lazy { Servers::httpd->factory() };
    $self->{'_serviceManager'} = lazy { iMSCP::Service->getInstance(); };
    $self->{'_phpConfigObject'} = lazy { tied %{ $self->{'_httpd'}->{'phpConfig'} }; };
    $self->{'_isSetupContext'} = defined $::execmode && $::execmode eq 'setup';
    $self->{'_isPhpFpm'} = $::imscpConfig{'HTTPD_SERVER'} eq 'apache_php_fpm';
    $self->{'_needNginxReload'} = 0;
    $self->{'_fpmInstancesToReload'} = {};

    if ( $self->{'_isPhpFpm'}
        && grep ( $self->{'action'}, qw/ change update enable run / )
    ) {
        # Override the Servers::httpd::apache_php_fpm::restart method to
        # restart/reload FPM instances and httpd server  
        require Servers::httpd::apache_php_fpm;
        no warnings 'redefine';
        *Servers::httpd::apache_php_fpm::restart = sub { $self->_restartFpmInstancesAndHttpdServer(); };
    }

    # Alias needed due to a bug in i-MSCP core up-to version 1.5.3-2018120800
    # iMSCP::File::remove method not implemented, called in iMSCP::Service::remove
    *iMSCP::File::remove = \&iMSCP::File::delFile;

    $self;
}

=item _installDistributionPackages( )

 Install distribution packages

 Return void, die on failure

=cut

sub _installDistributionPackages
{
    my @packages = qw/
        cowbuilder devscripts eatmydata equivs libfile-fcntllock-perl quilt
    /;

    if ( $::imscpConfig{'DISTRO_ID'} eq 'debian' ) {
        push @packages, grep ($_ eq $::imscpConfig{'DISTRO_CODENAME'}, qw/ jessie stretch /) ? 'ubuntu-archive-keyring' : 'ubuntu-keyring';
    } elsif ( $::imscpConfig{'DISTRO_ID'} eq 'ubuntu' ) {
        push @packages, 'debian-archive-keyring';
    } else {
        push @packages, ( 'debian-archive-keyring', (
            grep ( $_ eq $::imscpConfig{'DISTRO_CODENAME'}, qw/ jessie ascii / ) ? 'ubuntu-archive-keyring' : 'ubuntu-keyring'
        ) );
    }

    my $rs = execute( [ '/usr/bin/apt-get', '--quiet', 'update' ], \my $stdout, \my $stderr );
    debug( $stdout ) if length $stdout;
    $rs ||= execute( [ '/usr/bin/apt-get', '-y', '--auto-remove', '--no-install-recommends', '--quiet', 'install', @packages ], \$stdout, \$stderr );
    $rs == 0 or die( $stderr || 'Unknown error' );
    debug( $stdout ) if length $stdout;
}

=item _uninstallDistributionPackages( )

 Uninstall distribution packages

 Return void, die on failure

=cut

sub _uninstallDistributionPackages
{
    my ( $self ) = @_;

    my ( $stdout, $stderr );
    my @packages;

    for my $dentry ( glob "$self->{'_thisPluginDir'}/PhpCompiler/patches/*" ) {
        next unless $dentry =~ m/(\d+\.\d+)$/;
        for my $package ( "imscp-psw-php$1-build-deps", "imscp-psw-php$1-runtime-dependencies" ) {
            my $rs = execute( [ '/usr/bin/dpkg-query', '-W', '-f=\'${Status}\'', $package ], \$stdout, \$stderr );
            debug( $stdout ) if length $stdout;
            push @packages, $package unless $rs || $stdout !~ /\binstalled\b/;
        }
    }

    return unless @packages;

    execute(
        [ '/usr/bin/apt-get', '-y', '--auto-remove', '--quiet', 'purge', @packages ], \$stdout, \$stderr
    ) == 0 or die( $stderr || 'Unknown error' );
    debug( $stdout ) if length $stdout;
}

=item _registerEventListeners( )

 Register event listeners

 Return void, die on failure

=cut

sub _registerEventListeners
{
    my ( $self ) = @_;

    return if $self->{'_listenersRegistered'};

    $self->{'_listenersRegistered'} = 1;

    unless ( grep ($_ eq $::imscpConfig{'HTTPD_SERVER'}, qw/ apache_php_fpm apache_fcgid /) ) {
        # None of FPM or FCGID httpd server implementation are involved.
        # Schedule plugin deactivation.
        # the plugin.
        $self->{'eventManager'}->register( 'onBeforeSetPluginStatus', sub {
            my ( $pluginName, $pluginStatus ) = @_;
            return 0 unless $pluginName eq 'PhpSwitcher';
            ${ $pluginStatus } = 'todisable';
            0;
        } ) == 0 or die( getMessageByType( 'error', { amount => 1, remove => 1 } ));
    }

    my $rs ||= $self->{'eventManager'}->register( 'onLoadTemplate', sub { $self->_overridePhpTemplates( @_ ); } );
    $rs ||= $self->{'eventManager'}->register(
        [ 'beforeHttpdStart', 'beforeHttpdRestart', 'beforeHttpdStop' ], sub { $self->resetHttpServerSettings( @_ ); }
    );
    $rs == 0 or die( getMessageByType( 'error', { amount => 1, remove => 1 } ));

    if ( $::imscpConfig{'HTTPD_SERVER'} eq 'apache_fcgid' ) {
        $self->{'eventManager'}->register( 'beforeHttpdAddCfg', sub {
            $self->_overrideHttpFcgidServerSettings( @_ );
        } ) == 0 or die( getMessageByType( 'error', { amount => 1, remove => 1 } ));
        return;
    }

    $rs ||= $self->{'eventManager'}->register(
        'beforeHttpdAddCfg', sub { $self->_overrideHttpFpmServerSettings( @_ ); }
    );
    $rs ||= $self->{'eventManager'}->register(
        [ 'afterHttpdBuildPhpConf', 'afterHttpdDisableDmn', 'afterHttpdDelDmn' ], sub { $self->_deleteObsoleteFpmConfig( @_ ); }
    );
    $rs == 0 or die( getMessageByType( 'error', { amount => 1, remove => 1 } ));

    if ( $self->{'_httpd'}->{'phpConfig'}->{'PHP_FPM_LISTEN_MODE'} ne 'uds' ) {
        return;
    }

    $self->{'eventManager'}->register( 'beforeHttpdBuildConf', sub { $self->_overrideFpmUdsPath( @_ ); } ) == 0 or die( getMessageByType(
        'error', { amount => 1, remove => 1 } )
    );
}

=item _checkPhpVersion( \%phpVersion )

 Check the given PHP version data

 Param hashref \%phpVersion PHP version data
 Return List PHP version components, die on failure

=cut

sub _checkPhpVersion
{
    my ( $self, $phpVersion ) = @_;

    my $versionPattern = qr/^PHP\s+((?:\d+.){2}\d+)((?:alpha|beta|RC)\d+)?/;
    my ( $stdout, $stderr, $rs, @errors ) = ( undef, undef, 0, () );

    # Check for PEAR directory existence
    -f "$phpVersion->{'version_pear_directory_path'}/PEAR.php" or push( @errors, sprintf(
        "Invalid PEAR directory: The '%s' directory doesn't exist or doesn't contain the PEAR.php file.",
        $phpVersion->{'version_pear_directory_path'}
    ));

    # Check for FastCGI binary existence
    -x $phpVersion->{'version_cgi_binary_path'} or push( @errors, sprintf(
        "Invalid PHP FastCGI binary: The '%s' binary file doesn't exist or is not executable.",
        $phpVersion->{'version_cgi_binary_path'}
    ));

    # Check for FPM binary existence
    -x $phpVersion->{'version_fpm_binary_path'} or push( @errors, sprintf(
        "Invalid PHP-FPM binary: The '%s' binary file doesn't exist or is not executable.",
        $phpVersion->{'version_fpm_binary_path'}
    ));

    # Check for PHP-FPM configuration file existence
    -f $phpVersion->{'version_fpm_config_file_path'} or push( @errors, sprintf(
        "Invalid PHP-FPM configuration file: The '%s' configuration file doesn't exist.",
        $phpVersion->{'version_fpm_config_file_path'}
    ));

    # Check for PHP-FPM pool directory existence
    -d $phpVersion->{'version_fpm_pool_directory_path'} or push( @errors, sprintf(
        "Invalid PHP-FPM pool directory: The '%s' directory doesn't exist.",
        $phpVersion->{'version_fpm_pool_directory_path'}
    ));

    !@errors or die( join( "\n", @errors ) . "\n" );

    # Check for FastCGI and PHP-FPM binaries validty and version matching

    execute( [ $phpVersion->{'version_cgi_binary_path'}, '-n', '-v' ], \$stdout, \$stderr ) == 0 or die( sprintf(
        "Couldn't get PHP version through the '%s' executable: %s\n",
        $phpVersion->{'version_cgi_binary_path'},
        $stderr
    ));

    $stdout =~ /$versionPattern.*?\s+\(cgi-fcgi\)/ or die( sprintf(
        "'%s' doesn't look like a PHP FastCGI binary.\n", $phpVersion->{'version_cgi_binary_path'}
    ));

    my ( $major, $minor, $tiny, $stage ) = ( split( /\./, $1 ), $2 // '' );

    execute( [ $phpVersion->{'version_fpm_binary_path'}, '-n', '-v' ], \$stdout, \$stderr ) == 0 or die( sprintf(
        "Couldn't get PHP version through the '%s' executable: %s\n",
        $phpVersion->{'version_fpm_binary_path'},
        $stderr
    ));

    $stdout =~ /$versionPattern.*?\s+\(fpm-fcgi\)/ or die( sprintf(
        "'%s' doesn't look like a PHP-FPM binary.\n", $phpVersion->{'version_fpm_binary_path'}
    ));

    "$major.$minor.$tiny$stage" eq $1 . ( $2 // '' ) or die( sprintf(
        "PHP FastCGI and PHP-FPM version mismatches: %s/%s\n", "$major.$minor.$tiny$stage", $1 . ( $2 // '' )
    ));

    my $isPackaged = $self->isPackagedPhpVersion( {
        version_major           => $major,
        version_minor           => $minor,
        version_cgi_binary_path => $phpVersion->{'version_cgi_binary_path'},
        version_fpm_binary_path => $phpVersion->{'version_fpm_binary_path'}
    } );

    my $config = $self->{'config'}->{ $isPackaged ? 'packaged' : 'compiled' };

    if ( !$isPackaged && -f "$phpVersion->{'version_fpm_pool_directory_path'}/www.conf.default" ) {
        iMSCP::File->new(
            filename => "$phpVersion->{'version_fpm_pool_directory_path'}/www.conf.default"
        )->delFile() == 0 or die( getMessageByType( 'error', {
            amount => 1, remove => 1 }
        ));
    }

    defined( my $cfgTpl = iMSCP::File->new(
        filename => $self->{'_thisPluginDir'} . '/PhpCompiler/templates/php/fpm/php-fpm.pool.default'
    )->get() ) or die( getMessageByType( 'error', {
        amount => 1, remove => 1
    } ));

    ( my $service = $config->{'php_fpm_service_name_pattern'} ) =~ s/%PHP_VERSION%/$major.$minor/g;

    $cfgTpl = process(
        {
            PHP_FPM_RUN_DIR      => $config->{'php_fpm_run_dir'},
            PHP_FPM_SERVICE_NAME => $service
        },
        $cfgTpl
    );

    my $file = iMSCP::File->new( filename => "$phpVersion->{'version_fpm_pool_directory_path'}/www.conf" );
    $rs = $file->set( $cfgTpl );
    $rs ||= $file->save();
    $rs ||= $file->owner( $::imscpConfig{'ROOT_USER'}, $::imscpConfig{'ROOT_GROUP'} );
    $rs ||= $file->mode( 0644 );
    $rs == 0 or die( getMessageByType( 'error', { amount => 1, remove => 1 } ));

    iMSCP::Dir->new( dirname => $config->{'php_fpm_log_dir'} )->make( {
        user  => $::imscpConfig{'ROOT_USER'},
        group => $::imscpConfig{'ROOT_GROUP'},
        mode  => 0755
    } );

    if ( execute(
        [ $phpVersion->{'version_fpm_binary_path'}, '--fpm-config', $phpVersion->{'version_fpm_config_file_path'}, '--test' ],
        \$stdout,
        \$stderr
    ) != 0 ) {
        if ( $stderr =~ /no pool defined/i ) {
            unless ( $isPackaged ) {
                unlink "$phpVersion->{'version_fpm_pool_directory_path'}/www.conf";
            }

            die( sprintf( "'%s' is not a valid PHP-FPM pool directory.\n", $phpVersion->{'version_fpm_pool_directory_path'} ));
        }

        die( sprintf( "'%s' is not a valid PHP-FPM configuration file: %s\n", $phpVersion->{'version_fpm_config_file_path'}, $stderr || 'Unknown error' ));
    }

    ( $major, $minor, $tiny, $stage );
}

=item _setupNginxMainConfigForPhpInfo( [ $action = configure ] )

 Add Nginx main configuration for the given PHP version info

 Param string action Action (configure|deconfigure)
 Return void, die on failure

=cut

sub _setupNginxMainConfigForPhpInfo
{
    my ( $self, $action ) = @_;
    $action //= 'configure';

    my $frontEndConfig = Package::FrontEnd->getInstance()->{'config'};

    for my $file (
        "$frontEndConfig->{'HTTPD_CONF_DIR'}/imscp_psw_fastcgi.conf",
        "$frontEndConfig->{'HTTPD_CONF_DIR'}/conf.d/imscp_psw.conf",
        "$frontEndConfig->{'HTTPD_CONF_DIR'}/imscp_psw.conf"
    ) {
        next unless -f $file;
        iMSCP::File->new( filename => $file )->delFile() == 0 or die( getMessageByType( 'error', { amount => 1, remove => 1 } ));
    }

    if ( $action eq 'configure' ) {
        iMSCP::File->new( filename => $frontEndConfig->{'HTTPD_CONF_DIR'} . "/imscp_fastcgi.conf" )->copyFile(
            "$frontEndConfig->{'HTTPD_CONF_DIR'}/imscp_psw_fastcgi.conf"
        ) == 0 or die( getMessageByType( 'error', { amount => 1, remove => 1 } ));

        my $file = iMSCP::File->new( filename => $frontEndConfig->{'HTTPD_CONF_DIR'} . "/imscp_psw_fastcgi.conf" );

        defined( my $fileC = $file->getAsRef() ) or die( getMessageByType( 'error', { amount => 1, remove => 1 } ));

        ${ $fileC } =~ s/^fastcgi_pass.*\n//m;

        $file->save() == 0 or die( getMessageByType( 'error', { amount => 1, remove => 1 } ));

        $file = iMSCP::File->new( filename => "$frontEndConfig->{'HTTPD_CONF_DIR'}/imscp_psw.conf" );
        $file->set( <<"EOF" );
location ~ ^/shared/phpswitcher/(\\d+)\$ {
    root $self->{'_thisPluginDir'}/frontend/shared;

    try_files /phpinfo.php =404;
    include imscp_psw_fastcgi.conf;
    fastcgi_pass psw-php\$1;
}
EOF
        $file->save() == 0 or die( getMessageByType( 'error', { amount => 1, remove => 1 } ));
    }

    for my $site (
        "$frontEndConfig->{'HTTPD_SITES_AVAILABLE_DIR'}/00_master.conf",
        "$frontEndConfig->{'HTTPD_SITES_AVAILABLE_DIR'}/00_master_ssl.conf"
    ) {
        next unless -f $site;

        my $file = iMSCP::File->new( filename => $site );

        defined( my $fileC = $file->getAsRef() ) or die( getMessageByType( 'error', { amount => 1, remove => 1 } ));

        ${ $fileC } =~ s/^\s+include imscp_psw.conf;\n//m;

        if ( $action eq 'configure' ) {
            ${ $fileC } = replaceBloc(
                "# SECTION custom BEGIN.\n",
                "# SECTION custom END.\n",
                "    # SECTION custom BEGIN.\n"
                    . '    '
                    . getBloc(
                    "# SECTION custom BEGIN.\n",
                    "# SECTION custom END.\n",
                    ${ $fileC }
                )
                    . "    include imscp_psw.conf;\n"
                    . "    # SECTION custom END.\n",
                ${ $fileC }
            );
        }

        $file->save() == 0 or die( getMessageByType( 'error', { amount => 1, remove => 1 } ));
    }

    $self->{'_needNginxReload'} = 1;
}

=item _configurePhpVersionInfo( \%phpVersion )

 Configure PHP info for the given PHP version

 Param hashref \%phpVersion PHP version data
 Return void, die on failure

=cut

sub _configurePhpVersionInfo
{
    my ( $self, $phpVersion ) = @_;

    $self->_deconfigurePhpVersionInfo( $phpVersion );

    if ( $self->{'_isPhpFpm'} ) {
        my $frontEndConfig = Package::FrontEnd->getInstance()->{'config'};

        my $file = iMSCP::File->new( filename => $frontEndConfig->{'HTTPD_CONF_DIR'} . "/conf.d/imscp_psw.conf" );

        $file->save() == 0 or die( getMessageByType( 'error', { amount => 1, remove => 1 } )) unless -f $file->{'filename'};

        defined( my $fileC = $file->getAsRef() ) or die( getMessageByType( 'error', { amount => 1, remove => 1 } ));

        my $config = $self->{'config'}->{$self->isPackagedPhpVersion( $phpVersion ) ? 'packaged' : 'compiled'};

        ( my $sockPath = $config->{'php_fpm_run_dir'} . "/$config->{'php_fpm_service_name_pattern'}-www.sock" ) =~ s/%PHP_VERSION%/$phpVersion->{'version_name'}/g;

        ${ $fileC } .= <<"EOF";
# PHP VERSION ID $phpVersion->{'version_id'} - Begin
upstream psw-php$phpVersion->{'version_id'} {
    server unix:$sockPath;
}
# PHP VERSION ID $phpVersion->{'version_id'} - Ending
EOF
        $file->save() == 0 or die( getMessageByType( 'error', { amount => 1, remove => 1 } ));

        $self->{'_needNginxReload'} = 1;
        return;
    }

    my $ug = $::imscpConfig{'SYSTEM_USER_PREFIX'}
        . $::imscpConfig{'SYSTEM_USER_MIN_UID'};

    iMSCP::Dir->new( dirname => "$self->{'_thisPluginDir'}/phpinfo" )->make( {
        user  => $ug,
        group => $ug,
        mode  => 0700
    } );

    my $stderr;
    execute(
        [ $phpVersion->{'version_cgi_binary_path'}, '-q', '-i' ], \my $stdout, \$stderr
    ) == 0 or die( sprintf( "Couldn't generate phpinfo file: %s", $stderr ));

    my $file = iMSCP::File->new( filename => "$self->{'_thisPluginDir'}/phpinfo/" . "$phpVersion->{'version_id'}.html" );
    my $rs = $file->set( $stdout );
    $rs ||= $file->save();
    $rs ||= $file->owner( $ug, $ug );
    $rs ||= $file->mode( 0600 );
    $rs == 0 or die( getMessageByType( 'error', { amount => 1, remove => 1 } ));
}

=item _deconfigurePhpVersionInfo( \%phpVersion )

 Deconfigure PHP info for the given PHP version

 Param hashref \%phpVersion PHP version data
 Return void, die on failure

=cut

sub _deconfigurePhpVersionInfo
{
    my ( $self, $phpVersion ) = @_;

    my $frontEndConfig = Package::FrontEnd->getInstance()->{'config'};

    if ( -f "$frontEndConfig->{'HTTPD_CONF_DIR'}/conf.d/imscp_psw.conf" ) {
        my $file = iMSCP::File->new(
            filename => $frontEndConfig->{'HTTPD_CONF_DIR'} . "/conf.d/imscp_psw.conf"
        );
        defined( my $fileC = $file->getAsRef() ) or die( getMessageByType( 'error', { amount => 1, remove => 1 } ));

        ${ $fileC } = replaceBloc(
            "# PHP VERSION ID $phpVersion->{'version_id'} - Begin\n",
            "# PHP VERSION ID $phpVersion->{'version_id'} - Ending\n",
            '',
            ${ $fileC }
        );

        $file->save() == 0 or die( getMessageByType( 'error', { amount => 1, remove => 1 } ));

        $self->{'_needNginxReload'} = 1;
    }

    if ( -f "$self->{'_thisPluginDir'}/phpinfo/$phpVersion->{'version_id'}.html" ) {
        iMSCP::File->new( filename => "$self->{'_thisPluginDir'}/phpinfo/" . "$phpVersion->{'version_id'}.html" )->delFile() == 0 or die(
            getMessageByType( 'error', { amount => 1, remove => 1 } )
        );
    }
}

=item _initDatabase

 Initialize database for the PhpSwitcher plugin
 
 - Insert (or update) default PHP version in database

 Return void, die on failure

=cut

sub _initDatabase
{
    my ( $self ) = @_;

    local $self->{'_dbh'}->{'RaiseError'} = 1;

    my ( $version ) = `$self->{'_httpd'}->{'phpConfig'}->{'PHP_CLI_BIN_PATH'} -n -v 2> /dev/null`
        =~ /^PHP\s+((?:(?:\d+.){2}\d+)(?:(?:alpha|beta|RC)\d+)?)/;
    length $version or die( "Couldn't guess default PHP version." );

    my ( $versionName ) = $version =~ /^(\d+\.\d+)/;

    $self->{'_dbh'}->do(
        "
            INSERT INTO `$self->{'config'}->{'database'}->{'php_version_table'}` (
                `version_version`,
                `version_name`,
                `version_pear_directory_path`,
                `version_cgi_binary_path`,
                `version_fpm_binary_path`,
                `version_fpm_config_file_path`,
                `version_fpm_pool_directory_path`,
                `version_is_packaged`,
                `version_is_default`,
                `version_status`
            ) VALUES (
                ?, ?, ?, ?, ?, ?, ?, 1, 1, 'ok'
            ) ON DUPLICATE KEY UPDATE
                `version_version` = ?,
                `version_name` = ?,
                `version_pear_directory_path` = ?,
                `version_cgi_binary_path` = ?,
                `version_fpm_binary_path` = ?,
                `version_fpm_config_file_path` = ?,
                `version_fpm_pool_directory_path` = ?,
                `version_is_packaged` = 1,
                `version_is_default` = 1,
                `version_status` = 'ok'
        ",
        undef,
        $version,
        $versionName,
        $self->{'_httpd'}->{'phpConfig'}->{'PHP_PEAR_DIR'},
        $self->{'_httpd'}->{'phpConfig'}->{'PHP_FCGI_BIN_PATH'},
        $self->{'_httpd'}->{'phpConfig'}->{'PHP_FPM_BIN_PATH'},
        "/etc/php/$versionName/fpm/php-fpm.conf",
        $self->{'_httpd'}->{'phpConfig'}->{'PHP_FPM_POOL_DIR_PATH'},
        $version,
        $versionName,
        $self->{'_httpd'}->{'phpConfig'}->{'PHP_PEAR_DIR'},
        $self->{'_httpd'}->{'phpConfig'}->{'PHP_FCGI_BIN_PATH'},
        $self->{'_httpd'}->{'phpConfig'}->{'PHP_FPM_BIN_PATH'},
        "/etc/php/$versionName/fpm/php-fpm.conf",
        $self->{'_httpd'}->{'phpConfig'}->{'PHP_FPM_POOL_DIR_PATH'}
    );
}

=item _activatePhpFpmService( \%phpVersion )

 Activate PHP-FPM service for the given PHP version

 Param hashref \%phpVersion PHP version data
 Return void die on failure

=cut

sub _activatePhpFpmService
{
    my ( $self, $phpVersion ) = @_;

    my $isPackaged = $self->isPackagedPhpVersion( $phpVersion );
    my $config = $self->{'config'}->{$isPackaged ? 'packaged' : 'compiled'};
    ( my $service = $config->{'php_fpm_service_name_pattern'} ) =~ s/%PHP_VERSION%/$phpVersion->{'version_name'}/g;

    unless ( $isPackaged ) {
        ( my $fpmPidFile = $config->{'php_fpm_pid_file_pattern'} ) =~ s/%PHP_VERSION%/$phpVersion->{'version_name'}/g;
        ( my $tmpFile = $config->{'php_fpm_tmpfile_pattern'} ) =~ s/%PHP_VERSION%/$phpVersion->{'version_name'}/g;
        my $variables = {
            PHP_FPM_BINARY_DIR     => dirname( $phpVersion->{'version_fpm_binary_path'} ),
            PHP_FPM_BINARY         => basename( $phpVersion->{'version_fpm_binary_path'} ),
            PHP_FPM_CONF_FILE_PATH => $phpVersion->{'version_fpm_config_file_path'},
            PHP_FPM_LIB_DIR        => $config->{'php_fpm_lib_dir'},
            PHP_FPM_PID_FILE       => $fpmPidFile,
            PHP_FPM_RUN_DIR        => $config->{'php_fpm_run_dir'},
            PHP_FPM_TMPFILE        => $tmpFile,
            PHP_FPM_SERVICE_NAME   => $service,
            PHP_VERSION            => $phpVersion->{'version_name'},
            SYS_TMPFILES_DIR       => $config->{'sys_tmpfiles_dir'},
        };

        my %files = (
            $config->{'php_fpm_systemd_unit_pattern'} => {
                template  => $self->{'_thisPluginDir'} . '/PhpCompiler/templates/php/fpm/php-fpm.service',
                targetDir => $config->{'sys_systemd_unit_dir'},
                mode      => 0644
            },
            $config->{'php_fpm_sysvinit_pattern'}     => {
                template  => $self->{'_thisPluginDir'} . '/PhpCompiler/templates/php/fpm/php-fpm.init',
                targetDir => $config->{'sys_sysvinit_dir'},
                mode      => 0755
            }
        );

        while ( my ( $filePattern, $fileProps ) = each( %files ) ) {
            # Skip entry if target directory doesn't exists
            next unless -d $fileProps->{'targetDir'};

            defined( my $tplContent = iMSCP::File->new( filename => $fileProps->{'template'} )->get() ) or die(
                getMessageByType( 'error', { amount => 1, remove => 1 } )
            );

            $tplContent = process( $variables, $tplContent );

            ( my $filename = $filePattern ) =~ s/%PHP_VERSION%/$phpVersion->{'version_name'}/g;
            my $file = iMSCP::File->new( filename => "$fileProps->{'targetDir'}/$filename" );
            my $rs = $file->set( $tplContent );
            $rs ||= $file->save();
            $rs ||= $file->owner( $::imscpConfig{'ROOT_USER'}, $::imscpConfig{'ROOT_GROUP'} );
            $rs ||= $file->mode( $fileProps->{'mode'} );
            $rs == 0 or die( getMessageByType( 'error', { amount => 1, remove => 1 } ));
        }
    }

    $self->{'_serviceManager'}->enable( $service );
    $self->{'_serviceManager'}->start( $service );
}

=item _deactivatePhpFpmService( \%phpVersion )

 Deactivate PHP-FPM service for the given PHP version

 Param hashref \%phpVersion PHP version data
 Return void, die on failure

=cut

sub _deactivatePhpFpmService
{
    my ( $self, $phpVersion ) = @_;

    my $isPackaged = $self->isPackagedPhpVersion( $phpVersion );
    my $config = $self->{'config_prev'}->{$isPackaged ? 'packaged' : 'compiled'};
    ( my $service = $config->{'php_fpm_service_name_pattern'} ) =~ s/%PHP_VERSION%/$phpVersion->{'version_name'}/g;

    return if $phpVersion->{'version_is_default'} || !$self->{'_serviceManager'}->hasService( $service );

    if ( $isPackaged ) {
        # For a packaged PHP version we must not remove the service
        $self->{'_serviceManager'}->stop( $service );
        $self->{'_serviceManager'}->disable( $service );
        return;
    }

    $self->{'_serviceManager'}->remove( $service );

    # Needed due to a bug in i-MSCP core up-to version 1.5.3-2018120800 which
    # prevent deletion of SysVInit scripts when they are named with a dot such
    # as psw7.4-fpm, and when the init provider is Systemd.
    ( my $sysVinitScript = $config->{'php_fpm_sysvinit_pattern'} ) =~ s/%PHP_VERSION%/$phpVersion->{'version_name'}/g;

    $self->{'_serviceManager'}->getProvider( 'SysVinit' )->remove( $sysVinitScript );

    return unless $self->{'_serviceManager'}->isSystemd();

    my $provider = $self->{'_serviceManager'}->getProvider();

    # The daemonReload() method has been added in i-MSCP version 1.5.3
    # (build 2018120700). See #37

    if ( my $sub = $provider->can( 'daemonReload' ) ) {
        $sub->( $provider );
        return;
    }

    my $stderr;
    execute( [ '/bin/systemctl', 'daemon-reload' ], \my $stdout, \$stderr ) == 0 or die( sprintf(
        "Couldn't reload systemd daemon: %s", $stderr || 'Unknown error'
    ));
    debug( $stdout ) if length $stdout;
}

=item _configureFpm( \%phpVersion )

 Configure FPM for the given PHP version

 Param hashref \%phpVersion PHP version data
 Return void, die on failure

=cut

sub _configureFpm
{
    my ( $self, $phpVersion ) = @_;

    return unless length $phpVersion->{'version_version'} && !$phpVersion->{'version_is_default'};

    my $isPackaged = $self->isPackagedPhpVersion( $phpVersion );
    my $config = $self->{'config'}->{$isPackaged ? 'packaged' : 'compiled'};

    unless ( $isPackaged ) {
        ( my $logrotateFile = $config->{'php_fpm_logrotate_file_pattern'} ) =~ s/%PHP_VERSION%/$phpVersion->{'version_name'}/g;
        ( my $reopenlogsScript = $config->{'php_fpm_reopenlogs_script_pattern'} ) =~ s/%PHP_VERSION%/$phpVersion->{'version_name'}/g;
        ( my $tmpFile = $config->{'php_fpm_tmpfile_pattern'} ) =~ s/%PHP_VERSION%/$phpVersion->{'version_name'}/g;

        my $phpVersionRootDir = dirname( dirname( $phpVersion->{'version_fpm_binary_path'} ));
        my $templatesDir = $self->{'_thisPluginDir'} . '/PhpCompiler/templates/php';
        my %files = (
            "$templatesDir/fpm/php-fpm.logrotate"             => {
                filename => "$config->{'sys_logrotate_dir'}/$logrotateFile",
                user     => $::imscpConfig{'ROOT_USER'},
                group    => $::imscpConfig{'ROOT_GROUP'},
                mode     => 0644
            },
            "$templatesDir/fpm/php-fpm.reopenlogs"            => {
                filename => "$config->{'php_fpm_lib_dir'}/$reopenlogsScript",
                user     => $::imscpConfig{'ROOT_USER'},
                group    => $::imscpConfig{'ROOT_GROUP'},
                mode     => 0755
            },
            "$templatesDir/fpm/php-fpm.tmpfile"               => {
                filename => "$config->{'sys_tmpfiles_dir'}/$tmpFile",
                user     => $::imscpConfig{'ROOT_USER'},
                group    => $::imscpConfig{'ROOT_GROUP'},
                mode     => 0644
            },
            "$templatesDir/$phpVersion->{'version_name'}.ini" => {
                filename => $phpVersionRootDir . '/etc/php/php.ini',
                user     => $::imscpConfig{'ROOT_USER'},
                group    => $::imscpConfig{'ROOT_GROUP'},
                mode     => 0644
            }
        );
        ( my $logFile = $config->{'php_fpm_log_file_pattern'} ) =~ s/%PHP_VERSION%/$phpVersion->{'version_name'}/g;
        ( my $pidFile = $config->{'php_fpm_pid_file_pattern'} ) =~ s/%PHP_VERSION%/$phpVersion->{'version_name'}/g;
        my $variables = {
            PHP_FPM_BINARY_DIR        => $phpVersionRootDir . '/sbin',
            PHP_FPM_BINARY            => basename( $phpVersion->{'version_fpm_binary_path'} ),
            PHP_FPM_CONF_FILE_PATH    => $phpVersion->{'version_fpm_config_file_path'},
            PHP_FPM_LOG_DIR           => $config->{'php_fpm_log_dir'},
            PHP_FPM_LOG_FILE          => $logFile,
            PHP_FPM_LIB_DIR           => $config->{'php_fpm_lib_dir'},
            PHP_FPM_REOPENLOGS_SCRIPT => $reopenlogsScript,
            PHP_FPM_RUN_DIR           => $config->{'php_fpm_run_dir'},
            PHP_FPM_PID_FILE          => $pidFile,
            # Defaults. These parameters are overridden through pool
            # configuration files
            HOME_DIR                  => '',
            PEAR_DIR                  => $phpVersion->{'version_pear_directory_path'},
            DISABLE_FUNCTIONS         => '',
            MAX_EXECUTION_TIME        => '30',
            MAX_INPUT_TIME            => '-1',
            MEMORY_LIMIT              => '128',
            ERROR_REPORTING           => 'E_ALL & ~E_NOTICE',
            DISPLAY_ERRORS            => '1',
            POST_MAX_SIZE             => '8',
            TMPDIR                    => '/tmp',
            UPLOAD_MAX_FILESIZE       => '2',
            ALLOW_URL_FOPEN           => '1',
            TIMEZONE                  => $::imscpConfig{'TIMEZONE'},
            EMAIL_DOMAIN              => 'root@localhost',
        };

        while ( my ( $srcFile, $targetFile ) = each( %files ) ) {
            my $rs = $self->{'eventManager'}->trigger( 'onLoadTemplate', 'PhpSwitcher', $srcFile, \my $cfgTpl, $variables );
            return $rs if $rs;

            unless ( defined $cfgTpl ) {
                defined( $cfgTpl = iMSCP::File->new( filename => $srcFile )->get() ) or die(
                    getMessageByType( 'error', { amount => 1, remove => 1 } )
                );
            }

            my $file = iMSCP::File->new( filename => $targetFile->{'filename'} );
            $rs = $file->set( process( $variables, $cfgTpl ));
            $rs ||= $file->save();
            $rs ||= $file->owner( $targetFile->{'user'}, $targetFile->{'group'} );
            $rs ||= $file->mode( $targetFile->{'mode'} );
            $rs == 0 or die( getMessageByType( 'error', { amount => 1, remove => 1 } ));
        }

        if ( -d '/run/systemd/system' ) {
            my $stderr;
            execute(
                [ '/bin/systemd-tmpfiles', '--create', "$config->{'sys_tmpfiles_dir'}/$tmpFile" ], \$stderr, \my $stdout
            ) == 0 or die( $stderr );
            debug( $stdout ) if $stdout;
        }
    }

    $self->_activatePhpFpmService( $phpVersion );
}

=item _deconfigureFpm( \%phpVersion )

 Deconfigure FPM for the given PHP version

 Param hashref \%phpVersion PHP version data
 Return void, die on failure

=cut

sub _deconfigureFpm
{
    my ( $self, $phpVersion ) = @_;

    return unless length $phpVersion->{'version_version'};

    $self->_deactivatePhpFpmService( $phpVersion );

    # Even for a packaged PHP version, we process as if this is a compiled PHP
    # version. This cover case where a compiled PHP version is replaced by a
    # packaged PHP version.
    my $config = $self->{'config_prev'}->{'compiled'};

    ( my $logrotateFile = $config->{'php_fpm_logrotate_file_pattern'} ) =~ s/%PHP_VERSION%/$phpVersion->{'version_name'}/g;
    ( my $reopenlogsScript = $config->{'php_fpm_reopenlogs_script_pattern'} ) =~ s/%PHP_VERSION%/$phpVersion->{'version_name'}/g;
    ( my $tmpFile = $config->{'php_fpm_tmpfile_pattern'} ) =~ s/%PHP_VERSION%/$phpVersion->{'version_name'}/g;
    ( my $logFile = $config->{'php_fpm_log_file_pattern'} ) =~ s/%PHP_VERSION%/$phpVersion->{'version_name'}/g;
    ( my $pidFile = $config->{'php_fpm_pid_file_pattern'} ) =~ s/%PHP_VERSION%/$phpVersion->{'version_name'}/g;

    for my $file (
        "$config->{'php_fpm_lib_dir'}/$reopenlogsScript",
        "$config->{'php_fpm_log_dir'}/$logFile",
        "$config->{'php_fpm_run_dir'}/$pidFile",
        "$config->{'sys_logrotate_dir'}/$logrotateFile",
        "$config->{'sys_tmpfiles_dir'}/$tmpFile"
    ) {
        next unless -f $file;
        iMSCP::File->new( filename => $file )->delFile() == 0 or die(
            getMessageByType( 'error', { amount => 1, remove => 1 } )
        );
    }

    return unless -d $phpVersion->{'version_fpm_pool_directory_path'};

    unlink grep !/www\.conf$/, glob "$phpVersion->{'version_fpm_pool_directory_path'}/*.conf";
}

=item _getDefaultPhpVersion

 Get default PHP version

 Return hashref, die on failure

=cut

sub _getDefaultPhpVersion
{
    my ( $self ) = @_;

    $self->{'_defaultPhpVersion'} //= do { ( grep (
        $_->{'version_is_default'}, values %{ $self->getPhpVersions() }
    ) )[0] or die( "Couldn't find default PHP version.\n" ); };
}

=item _getDomainPhpVersionMap

 Get domain PHP version map

 Return void, die on failure

=cut

sub _getDomainPhpVersionMap
{
    my ( $self ) = @_;

    $self->{'_domainPhpVersionMap'} //= do {
        local $self->{'_dbh'}->{'RaiseError'} = 1;
        $self->{'_dbh'}->selectall_hashref(
            "
                SELECT `version_id`, `domain_id`, `domain_type`, `domain_name`
                FROM `$self->{'config'}->{'database'}->{'domain_php_version_table'}`
            ",
            'domain_name'
        );
    };
}

=item _getDomainPhpVersion( $domain [, $status ] )

 Get domain PHP version matching the given criterias

 Param string $domain Domain name criteria 
 Param string $status Status PHP version status criteria
 Return hashref if a PHP version is found, undef otherwise, die on failure

=cut

sub _getDomainPhpVersion
{
    my ( $self, $domain, $status ) = @_;

    my $domainPhpVersionId = $self->_getDomainPhpVersionMap()->{$domain}->{'version_id'};
    my $phpVersion = $domainPhpVersionId ? $self->getPhpVersions()->{$domainPhpVersionId} : $self->_getDefaultPhpVersion();

    !defined $status ? $phpVersion : ( $phpVersion->{'version_status'} eq $status ? $phpVersion : $self->_getDefaultPhpVersion() );
}

=item _scheduleDomainsChange ( $phpVersionId )

 Schedule change of domains for which PHP version matches with the given PHP
 version

 Param string $versionId PHP version unique identifier
 Return void, die on failure

=cut

sub _scheduleDomainsChange
{
    my ( $self, $phpVersionId ) = @_;

    my $domainPhpVersionMap = $self->_getDomainPhpVersionMap();

    for my $domainPhpVersion ( values %{ $domainPhpVersionMap } ) {
        next unless $domainPhpVersion->{'version_id'} eq $phpVersionId;

        if ( $domainPhpVersion->{'domain_type'} eq 'dmn' ) {
            $self->{'_dbh'}->do(
                "
                    UPDATE `domain`
                    SET `domain_status` = 'tochange'
                    WHERE `domain_id` = ?
                    AND `domain_status` NOT IN('disabled', 'todelete')
                ",
                undef,
                $domainPhpVersion->{'domain_id'}
            );
            next;
        }

        if ( $domainPhpVersion->{'domain_type'} eq 'sub' ) {
            $self->{'_dbh'}->do(
                "
                    UPDATE `subdomain`
                    SET `subdomain_status` = 'tochange'
                    WHERE `subdomain_id` = ?
                    AND `subdomain_status` NOT IN('disabled', 'todelete')
                ",
                undef,
                $domainPhpVersion->{'domain_id'}
            );
            next;
        }

        if ( $domainPhpVersion->{'domain_type'} eq 'als' ) {
            $self->{'_dbh'}->do(
                "
                    UPDATE `domain_aliasses`
                    SET `alias_status` = 'tochange'
                    WHERE `alias_id` = ?
                    AND `alias_status` NOT IN('disabled', 'todelete')
                ",
                undef,
                $domainPhpVersion->{'domain_id'}
            );
            next;
        }

        $self->{'_dbh'}->do(
            "
                UPDATE `subdomain_alias`
                SET `subdomain_alias_status` = 'tochange'
                WHERE `subdomain_alias_id` = ?
                AND `subdomain_alias_status` NOT IN('disabled', 'todelete')
            ",
            undef,
            $domainPhpVersion->{'domain_id'}
        );
    }
}

=item _restartFpmInstancesAndHttpdServer

 Override the Servers::httpd::apache_php_fpm::restart method to restart/reload
 FPM instances and httpd server

 Return int 0 on success, other on failure

=cut

sub _restartFpmInstancesAndHttpdServer
{
    my ( $self ) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdRestart' );
    return $rs if $rs;

    eval {
        my $phpVersions = $self->getPhpVersions();
        for my $phpVersionId ( keys %{ $self->{'_fpmInstancesToReload'} } ) {
            my $phpVersion = $phpVersions->{$phpVersionId};

            next unless $phpVersion->{'version_is_default'} || $phpVersion->{'version_status'} eq 'ok';

            my $config = $self->{'config'}->{$self->isPackagedPhpVersion( $phpVersion ) ? 'packaged' : 'compiled'};
            ( my $service = $config->{'php_fpm_service_name_pattern'} ) =~ s/%PHP_VERSION%/$phpVersion->{'version_name'}/g;

            if ( $self->{'_httpd'}->{'forceRestart'} ) {
                $self->{'_serviceManager'}->restart( $service );
                return;
            }

            $self->{'_serviceManager'}->reload( $service );
        }

        if ( $self->{'_httpd'}->{'forceRestart'} ) {
            $self->{'_serviceManager'}->restart( $self->{'_httpd'}->{'config'}->{'HTTPD_SNAME'} );
            return;
        }

        $self->{'_serviceManager'}->reload( $self->{'_httpd'}->{'config'}->{'HTTPD_SNAME'} );
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    $self->{'eventManager'}->trigger( 'afterHttpdRestart' );
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
