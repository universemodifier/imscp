#!/usr/bin/perl
# i-MSCP PhpSwitcher plugin
#
# @author Laurent Declercq <l.declercq@nuxwin.com>
# @copyright (C) 2014-2019 Laurent Declercq <l.declercq@nuxwin.com>
# @license i-MSCP License <https://www.i-mscp.net/license-agreement.html>

use strict;
use warnings;
use File::Basename qw/ basename dirname fileparse /;
use File::Spec;
use File::Temp;
use FindBin;
use lib "$FindBin::Bin/../../../../engine/PerlLib",
    "$FindBin::Bin/../../../../engine/PerlVendor";
use DateTime;
use iMSCP::Bootstrapper;
use iMSCP::Cwd '$CWD';
use iMSCP::Database;
use iMSCP::DbTasksProcessor;
use iMSCP::Debug qw/ error output setVerbose getMessageByType /;
use iMSCP::Dir;
use iMSCP::Execute qw/ execute executeNoWait escapeShell /;
use iMSCP::File;
use iMSCP::Getopt;
use iMSCP::TemplateParser 'process';
use POSIX 'locale_h';
use Servers::httpd;
use version;

$ENV{'LANG'} = 'C.UTF-8';
delete $ENV{'LANGUAGE'};
setlocale( LC_MESSAGES, 'C.UTF-8' );

# Restore default behavior for SIGINT
$SIG{'INT'} = 'DEFAULT';

iMSCP::Bootstrapper->getInstance()->boot( {
    norequirements  => 'yes',
    mode            => 'backend',
    nolock          => 'yes',
    config_readonly => 'yes'
} );

STDOUT->autoflush( 1 );
STDERR->autoflush( 1 );

# Download directory
my $DOWNLOAD_DIRECTORY = '/usr/local/src/phpswitcher';

# Build directory
my $BUILD_DIRECTORY = $DOWNLOAD_DIRECTORY;

# Base installation directory
my $INSTALLATION_DIRECTORY = '/opt/phpswitcher/' . DateTime->now()->ymd( '' );

# Base directory for static paths
my $STATIC_PATHS_BASE_DIR = '/opt/phpswitcher/static';

# Default number of parallel jobs
my $NUMBER_JOBS //= &psw_get_number_cpu_cores();

# Map PHP version names to tiny PHP versions (last known tiny PHP versions)
my %VERSION_NAME_TO_VERSION_TINY_MAP = (
    '5.3' => '5.3.29', # End of life: 14 August 2014 - Reached
    #'5.4' => '5.4.45', # End of life: 3 September 2015 - Reached
    #'5.5' => '5.5.38', # End of life: 21 July 2016 - Reached
    '5.6' => '5.6.40', # End of life: 31 December 2018 - Reached
    '7.0' => '7.0.33', # End of life: 01 December 2018 - Reached
    '7.1' => '7.1.33', # End of life: 01 December 2019
    '7.2' => '7.2.24', # End of life: 30 November 2020
    '7.3' => '7.3.11', # End of life: 06 December 2021
    '7.4' => [         # End of life: December 2022 - Unreleased yet
        '7.4.0RC4', 'https://downloads.php.net/~derick/php-7.4.0RC4.tar.gz'
    ]
);

iMSCP::Getopt->parseNoDefault( sprintf( "Usage: perl %s [OPTION]... [@{ [ join '|', sort keys %VERSION_NAME_TO_VERSION_TINY_MAP ] }]...", basename( $0 )) . qq{

PHP Compiler

This script compile and install the various PHP versions. It can also register the compiled and/or packaged PHP versions in the PhpSwitcher plugin.

REGISTRATION

When the --register option is passed-in, PHP versions found in the installation directory are automatically registered in the PhpSwitcher plugin.

If you want favor packaged PHP versions rather than compiled PHP versions, you must also pass the --packaged option, in which case, packaged PHP versions will be preferred when there are available.

You can also work with packaged PHP versions only, by passing the --packaged-only option.

Packaged PHP versions are considered only if the CGI/FPM SAPIs and PEAR distribution are all installed on the system.

ENVIRONMENT VARIABLES

The script support environment variables to change the default behavior.

 PSW_DISTRIBUTION={devuan_jessie|jessie|stretch|buster|xenial|bionic|ascii}

This variable make it possible to change the target distribution. When the target distribution is a foreign distribution, the build will always be done in a chroot environment, and no PHP runtime dependencies will be installed on the system.

If the install MAKE(1) target is involved, the '-foreign' suffixe will be added to the installation directory.

 PSW_FCHROOT=1

When this variable is set, operations will executed in a chroot environnment, regardless of the involved MAKE(1) targets.

OPTIONS
 -a,    --register               Register PHP versions in the PhpSwitcher
                                 plugin. Ignored when the target distribution
                                 is a foreign distribution.

 -b,    --build-dir     {dir}    Build directory.
                                 Default: $BUILD_DIRECTORY

 -d,    --download-only          Download only mode.

 -e     --download-dir           Download directory.
                                 Default: $DOWNLOAD_DIRECTORY

 -f,    --force-last             Force download and build of latest PHP
                                 versions.

 -i,    --install-dir   {dir}    Installation directory.
                                 default $INSTALLATION_DIRECTORY

 -j,    --parallel-jobs {nn}     Number of parallel jobs for MAKE(1).
                                 Default: CPU cores + 1 : $NUMBER_JOBS

 -k     --keep-builddir          Keep current build directory.

 -n     --no-chroot              Don't operate in a chroot environment.
 
 -m     --no-static-paths        Don't create symlinks for static paths.

 -o,    --packaged-only          Only considere the packaged PHP versions. Only
                                 relevant with the --packaged option.

 -p,    --packaged               Favor registration of packaged PHP versions
                                 rather than compiled PHP versions when there
                                 are available. Only relevant with the
                                 --register option.

 -r,    --runtime-dependencies   Install the runtime dependencies for the
                                 involved PHP versions.

 -s,    --register--only         Skip download, build, and install processes
                                 when the no PHP version is found. Only
                                 relevant with the --register option.

 -t,    --make-target   {target} MAKE(1) target to execute. Pass this option
                                 multiple time for multiple targets.

 -v,    --verbose                Enable verbose mode.

 -z,    --zts                    Enable PHP ZTS support.
},
    'register|a'             => \my $REGISTER_FLAG,
    'build-dir|b=s'          => \$BUILD_DIRECTORY,
    'download-only|d'        => \my $DOWNLOAD_ONLY_FLAG,
    'download-dir|e=s'       => \$DOWNLOAD_DIRECTORY,
    'force-last|f'           => \my $FORCE_LAST_FLAG,
    'install-dir|i=s'        => \$INSTALLATION_DIRECTORY,
    'no-chroot|n'            => \my $NO_CHROOT_FLAG,
    'no-static-paths|m'      => \my $NO_STATIC_PATHS,
    'parallel-jobs|j=i'      => \$NUMBER_JOBS,
    'keep-builddir|k'        => \my $KEEP_BUILD_DIRECTORY_FLAG,
    'packaged|p'             => \my $PACKAGED_FLAG,
    'packaged-only|o'        => \my $PACKAGED_ONLY_FLAG,
    'register-only'          => \my $REGISTER_ONLY_FLAG,
    'runtime-dependencies|r' => \my $RUNTIME_DEPENDENCIES_FLAG,
    'make-target|t=s'        => \my @MAKE_TARGETS,
    'verbose|v'              => \&setVerbose,
    'zts|z'                  => \my $ZTS_FLAG
);

unless ( iMSCP::Bootstrapper->getInstance()->lock(
    '/var/lock/psw-php-compiler.lock', 1 )
) {
    print output(
        'Concurrent executions of the PHP compiler are forbidden!', 'warn'
    );
    exit 1;
}

$DOWNLOAD_DIRECTORY = File::Spec->canonpath( $DOWNLOAD_DIRECTORY );
$BUILD_DIRECTORY = File::Spec->canonpath( $BUILD_DIRECTORY );
$INSTALLATION_DIRECTORY = File::Spec->canonpath( $INSTALLATION_DIRECTORY );

@ENV{qw/ DEBFULLNAME DEBEMAIL /} = (
    'Laurent Declercq', 'l.declercq@nuxwin.com'
);

# Selected PHP versions
my @VERSION_NAMES = ();

# Set default MAKE(1) targets if none were set
@MAKE_TARGETS = ( 'clean', 'install' ) unless @MAKE_TARGETS;

# Patterns for PHP archives download URLs
my @DOWNLOAD_URL_PATTERNS = (
    'http://php.net/distributions/php-%s.tar.gz',
    'http://de1.php.net/distributions/php-%s.tar.gz',
    'http://de2.php.net/distributions/php-%s.tar.gz',
    'http://uk1.php.net/distributions/php-%s.tar.gz',
    'http://uk3.php.net/distributions/php-%s.tar.gz',
    'http://us1.php.net/distributions/php-%s.tar.gz',
    'http://us2.php.net/distributions/php-%s.tar.gz',
    'http://us3.php.net/distributions/php-%s.tar.gz'
);

# PHP download URLs
my %DOWNLOAD_URLS;

# Whether target distribution is a foreign distribution, that is, other than the
# system one
my $IS_FOREIGN_DISTRIBUTION = psw_guess_distribution()
    ne $::imscpConfig{'DISTRO_CODENAME'};

# Whether PHP build environment need to be setup
my $NEED_SETUP_PHP_BUILD_ENVIRONMENT = 1;

# Database table
my $DB_TABLE = 'php_switcher_version';

eval {
    my @errorsStack = ();

    if ( $ENV{'PSW_FCHROOT'} && $NO_CHROOT_FLAG ) {
        push @errorsStack, "You cannot pass the --no-chroot option when the PSW_FCHROOT environment variable is set.";
    }

    if ( $IS_FOREIGN_DISTRIBUTION ) {
        if ( $NO_CHROOT_FLAG ) {
            push @errorsStack, "You cannot pass the --no-chroot option when the target distribution is a foreign distribution.";
        }

        if ( $REGISTER_FLAG ) {
            push @errorsStack, "You cannot pass the --register option when the target distribution is a foreign distribution.";
        }

        if ( grep ( $_ eq 'install', @MAKE_TARGETS ) ) {
            push @errorsStack, "The MAKE(1) 'install' target cannot be involved when the target distribution is a foreign distribution.";
        }
    }

    if ( $REGISTER_FLAG && !grep ( $_ eq 'install', @MAKE_TARGETS ) ) {
        push @errorsStack, "You cannot pass the --register option when the MAKE(1) 'install' target isn't involved.";
    }

    if ( $REGISTER_ONLY_FLAG && !$REGISTER_FLAG ) {
        if ( $REGISTER_FLAG && !grep ( $_ eq 'install', @MAKE_TARGETS ) ) {
            push @errorsStack, "You cannot pass the --register-only option when the --register option is not involved.";
        }
    }

    if ( $PACKAGED_FLAG && !$REGISTER_FLAG ) {
        push @errorsStack, "The --packaged option requires the --register option."
    }

    if ( $PACKAGED_ONLY_FLAG && !$PACKAGED_FLAG ) {
        push @errorsStack, "The --packaged--only option requires the --packaged option."
    }

    unless ( @errorsStack ) {
        for my $target ( @MAKE_TARGETS ) {
            next if grep (
                $_ eq $target, qw/ clean patch unpatch configure build install /
            );
            push @errorsStack, sprintf( "Invalid MAKE(1) target: %s", $target );
        }

        if ( !@ARGV ) {
            # When no PHP version is specified as argument, we assume all
            # supported PHP versions.
            @VERSION_NAMES = keys %VERSION_NAME_TO_VERSION_TINY_MAP;
        } else {
            # When one or many PHP versions are specified on the command line,
            # we need check that they are effectively supported, else, we need
            # raise an error.
            for my $versionName ( @ARGV ) {
                if ( exists $VERSION_NAME_TO_VERSION_TINY_MAP{$versionName} ) {
                    push @VERSION_NAMES, $versionName;
                    next;
                }

                push @errorsStack, sprintf(
                    "Invalid PHP version: %s", $versionName
                );
            }
        }

        @VERSION_NAMES = sort @VERSION_NAMES;
    }

    if ( @errorsStack ) {
        print STDERR <<"EOF";

@{ [ join( "\n", @errorsStack ) ]}
EOF
        iMSCP::Getopt->showUsage();
    }

    # Considere the download, compilation and installation phases only when
    # the compiled PHP versions must be taken into consideraion
    if ( !$PACKAGED_ONLY_FLAG ) {
        for my $versionName ( @VERSION_NAMES ) {
            # When the packaged PHP versions must be favored, and that a
            # packaged PHP version is found, or when the --register flag is
            # set, and that a compiled PHP version is found in the installation
            # directory, we need skip the download, compilation and install
            # phases.
            if ( $REGISTER_ONLY_FLAG
                || ( $PACKAGED_FLAG && psw_is_packaged_php_version( $versionName ) )
                || ( $REGISTER_FLAG && psw_is_compiled_php_version( $versionName ) )
            ) {
                if ( $RUNTIME_DEPENDENCIES_FLAG
                    && psw_is_compiled_php_version( $versionName )
                ) {
                    psw_install_php_runtime_dependency_package( $versionName );
                }

                next;
            } elsif ( $RUNTIME_DEPENDENCIES_FLAG
                && psw_is_compiled_php_version( $versionName )
            ) {
                psw_install_php_runtime_dependency_package( $versionName );
                next;
            }

            # If no PHP sources are found we go ahead. The sysadmin will be
            # warned that PHP sources were not found.
            next unless defined( my $versionTiny = psw_find_php_sources(
                $versionName
            ) );

            # PHP sources were found. We need download them. 
            psw_download_php_sources( $versionTiny );

            # We don't go further if the --download-only flag is set.
            next if $DOWNLOAD_ONLY_FLAG;

            # We process the compilation and installation phases (depending on
            # the involved MAKE(1) targets.
            psw_compile_and_install_php_version( $versionName, $versionTiny );
        }
    }

    # Register the PHP versions if the --register flag is set.
    psw_register_php_versions_in_phpswitcher_plugin() if $REGISTER_FLAG;
};
if ( $@ ) {
    error( $@ );
    exit 1;
}

sub psw_get_number_cpu_cores
{
    execute(
        '/bin/grep processor /proc/cpuinfo 2> /dev/null | /usr/bin/wc -l',
        \my $stdout
    );
    $stdout =~ /^(\d+)/;
    ( $1 || 1 )+1;
}

sub psw_find_php_sources
{
    my ( $versionName ) = @_;

    # alpha, beta and RC versions (statically defined)
    if ( ref $VERSION_NAME_TO_VERSION_TINY_MAP{$versionName} eq 'ARRAY' ) {
        $DOWNLOAD_URLS{$VERSION_NAME_TO_VERSION_TINY_MAP{$versionName}->[0]}
            = $VERSION_NAME_TO_VERSION_TINY_MAP{$versionName}->[1];

        my $ret = execute(
            [
                '/usr/bin/wget', '--prefer-family=IPv4', '--quiet', '--spider',
                $VERSION_NAME_TO_VERSION_TINY_MAP{$versionName}->[1]
            ]
        );
        if ( $ret == 0 ) {
            print output(
                sprintf(
                    'Found the PHP %s sources at %s',
                    $versionName,
                    $VERSION_NAME_TO_VERSION_TINY_MAP{$versionName}->[1]
                ),
                'info'
            );
            return $VERSION_NAME_TO_VERSION_TINY_MAP{$versionName}->[0];
        }

        print output(
            sprintf(
                "Couldn't find the PHP %s sources at %s - Skipping",
                $versionName,
                $VERSION_NAME_TO_VERSION_TINY_MAP{$versionName}->[1]
            ), 'error'
        );
        return undef;
    }

    print output( sprintf(
        'Scanning PHP site for the PHP %s sources...', $versionName
    ), 'info' );

    my ( $major ) = $versionName =~ /^(\d+)/;
    my ( $tiny ) = $VERSION_NAME_TO_VERSION_TINY_MAP{$versionName} =~ /(\d+)$/;
    my ( $ret, $furl ) = ( 0, undef );

    for my $purl ( @DOWNLOAD_URL_PATTERNS ) {
        do {
            my $url = sprintf( $purl, "$versionName.$tiny" );
            $ret = execute(
                [
                    '/usr/bin/wget', '--prefer-family=IPv4', '--quiet',
                    '--spider', $url
                ]
            );
            unless ( $ret ) {
                $furl = $url;
                $tiny++;
            }
        } while $ret == 0 && $FORCE_LAST_FLAG;

        last if $furl || $ret == 8;
    }

    unless ( $furl ) {
        # No version found, search in PHP museum
        do {
            my $url = sprintf(
                'http://museum.php.net/php%s/php-%s.tar.gz',
                $major,
                "$versionName.$tiny"
            );
            $ret = execute(
                [
                    '/usr/bin/wget', '--prefer-family=IPv4', '--quiet',
                    '--spider', $url
                ]
            );
            unless ( $ret ) {
                $furl = $url;
                $tiny++;
            }
        } while $ret == 0 && $FORCE_LAST_FLAG;
    }

    if ( $furl ) {
        $DOWNLOAD_URLS{$VERSION_NAME_TO_VERSION_TINY_MAP{$versionName}} = $furl;

        print output( sprintf(
            'Found PHP %s sources at %s', $versionName, $furl
        ), 'info' );
        return $versionName . '.' . --$tiny;
    }

    print output( sprintf(
        "Couldn't find any download URL for the PHP %s sources - Skipping",
        $versionName
    ), 'error' );
    undef;
}

sub psw_download_php_sources
{
    my ( $versionTiny ) = @_;

    my $archivePath = File::Spec->join(
        $DOWNLOAD_DIRECTORY, "php-$versionTiny.tar.gz"
    );
    my ( $stdout, $stderr );

    if ( -f $archivePath ) {
        print output( sprintf(
            'The PHP %s sources are already present in the %s directory. Skipping download.',
            $versionTiny,
            $DOWNLOAD_DIRECTORY
        ), 'info' );
        return;
    }

    print output( sprintf(
        'Downloading PHP %s sources into the %s directory...',
        $versionTiny,
        $DOWNLOAD_DIRECTORY
    ), 'info' );

    local $@;
    eval { iMSCP::Dir->new( dirname => $DOWNLOAD_DIRECTORY )->make(); };
    !$@ or die( sprintf(
        "Couldn't create the %s download directory: %s", $DOWNLOAD_DIRECTORY, $@
    ));

    execute(
        [
            '/usr/bin/wget', '--prefer-family=IPv4', '-t', '1',
            '-O', $archivePath,
            $DOWNLOAD_URLS{$versionTiny}
        ],
        \$stdout,
        \$stderr
    ) == 0 or die( sprintf(
        'An error occurred while downloading PHP %s sources: %s',
        $versionTiny,
        $stderr || 'Unknown error'
    ));
}

sub psw_compile_and_install_php_version
{
    my ( $versionName, $versionTiny ) = @_;

    my $sourcesDir = File::Spec->join( $BUILD_DIRECTORY, "php-$versionTiny" );
    my $installDir = $INSTALLATION_DIRECTORY;

    unless ( $KEEP_BUILD_DIRECTORY_FLAG && -d $sourcesDir ) {
        my $archp = File::Spec->join(
            $DOWNLOAD_DIRECTORY, "php-$versionTiny.tar.gz"
        );

        local $@;
        eval { iMSCP::Dir->new( dirname => $sourcesDir )->remove(); };
        !$@ or die( sprintf(
            "Couldn't remove the %s directory: %s", $sourcesDir, $@
        ));

        print output( sprintf(
            'Extracting the PHP %s archive into %s ...', $versionTiny, $sourcesDir
        ), 'info' );

        eval { iMSCP::Dir->new( dirname => $BUILD_DIRECTORY )->make(); };
        !$@ or die( sprintf(
            "Couldn't create %s build directory: %s", $BUILD_DIRECTORY, $@
        ));

        my $stderr = '';
        executeNoWait(
            [ '/bin/tar', '-xzf', $archp, '-C', $BUILD_DIRECTORY ],
            sub {},
            sub { $stderr .= $_[0]; }
        ) == 0 or die( sprintf(
            'An error occurred while extracting archive for PHP %s: %s',
            $versionTiny,
            $stderr || 'Unknown error'
        ));
    }

    my @buildOptions;

    if ( grep ( /(?:configure|build|install)/, @MAKE_TARGETS ) ) {
        @ENV{qw/ PHP_AUTOCONF PHP_AUTOHEADER PHP_AUTOM4TE /} = qw/
            autoconf autoheader autom4te
        /;

        push @buildOptions, "parallel=$NUMBER_JOBS";
        push @buildOptions, 'zts' if $ZTS_FLAG;
    }

    # Add the '-foreign' if the target distribution is not identical to the
    # system one.
    $installDir .= '-foreign' if $IS_FOREIGN_DISTRIBUTION;

    my $needInstall = !!grep ( $_ eq 'install', @MAKE_TARGETS );

    if ( $needInstall ) {
        eval { iMSCP::Dir->new( dirname => $installDir )->make(); };
        !$@ or die( sprintf(
            "Couldn't create installation directory: %s", $@
        ));
    }

    my $phpCompilerDir = dirname( __FILE__ );
    my @cmdExecutor;

    if ( $ENV{'PSW_FCHROOT'} || $IS_FOREIGN_DISTRIBUTION
        || ( ( $needInstall || grep ( /(?:configure|build)/, @MAKE_TARGETS ) ) && !$NO_CHROOT_FLAG )
    ) {
        psw_setup_php_build_environment( $versionName );

        # Inhibit "apt-key output should not be parsed (stdout is not a terminal)"
        # warning as we are not parsing the output...
        $ENV{'APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE'} = 1;
        
        $ENV{'PHP_VERSION'} = $versionName;

        my $distributorID = psw_guess_distributor_id();
        my $distribution = psw_guess_distribution();
        my $hookDir = "$phpCompilerDir/pbuilder/$distributorID/hook.d";

        @cmdExecutor = (
            '/usr/sbin/cowbuilder', '--execute', '--autocleanaptcache',
            '--basepath', ( length $ENV{'PSW_PBUILDER_BASEPATH_ROOT_DIR'}
                && -d $ENV{'PSW_PBUILDER_BASEPATH_ROOT_DIR'}
                ? $ENV{'PSW_PBUILDER_BASEPATH_ROOT_DIR'} : '/var/cache/pbuilder'
            ) . "/psw-@{ [ lc $distributorID ] }-$distribution.cow",
            '--configfile', "$phpCompilerDir/pbuilder/$distributorID/.pbuilderrc",
            '--bindmounts',
            "$phpCompilerDir $sourcesDir" . ( $needInstall ? " $installDir" : '' ),
            '--hookdir', $hookDir, '--'
        );
    } else {
        # Make sure to set the $BNOCHROOT flag
        # (covers case where the flag is implicit)
        $NO_CHROOT_FLAG = 1;

        # Fix possible "can not be used when making a shared object; recompile
        # with –fPIC ... libc-client.a..." compile time  error. This error
        # occurs when using the --with--pic option and when the
        # /usr/lib/x86_64-linux-gnu/libc-client.a  symlink to
        # /usr/lib/libc-client.a has been created manually.
        if ( -l '/usr/lib/x86_64-linux-gnu/libc-client.a' ) {
            unlink '/usr/lib/x86_64-linux-gnu/libc-client.a';
        }

        # Remove manually created symlink to curl if any (joximu howto)
        # See https://i-mscp.net/thread/20211-howto-php-7-2-7-3-on-debian-stretch-9-using-phpswitcher-4-0-3
        if ( -l '/usr/local/include/curl' ) {
            unlink '/usr/local/include/curl';
        }

        if ( $needInstall || grep ( /^(?:configure|build)$/, @MAKE_TARGETS) ) {
            psw_install_php_build_dependencies( $versionName );
        }
    }

    print output( sprintf(
        "Executing the %s MAKE(1) target(s) for PHP %s...",
        join( ', ', @MAKE_TARGETS ),
        $versionTiny
    ), 'info' );

    my $stderr = '';
    executeNoWait(
        [
            @cmdExecutor,
            @cmdExecutor
                ? "$phpCompilerDir/pbuilder/make_wrapper.sh" : '/usr/bin/make',
            '--directory', $sourcesDir,
            '--makefile', "$phpCompilerDir/Makefile",
            "PREFIX=$installDir",
            "PHP_QUILT_PATCH_DIR=$phpCompilerDir/patches/$versionName",
            "BUILD_OPTIONS=@buildOptions", @MAKE_TARGETS
        ],
        undef,
        sub { $stderr .= $_[0]; }
    ) == 0 or die( sprintf(
        "An error occurred while executing MAKE(1) target(s) for PHP %s: %s",
        $versionTiny,
        $stderr
    ));

    # We don't want operate on the host filesystem if the target distribution
    # isn't identical to the host distribution.
    return if $IS_FOREIGN_DISTRIBUTION;

    if ( $needInstall && !$ENV{'PSW_UNIT_TESTS'} ) {
        psw_install_php_runtime_dependency_package( $versionName );
        psw_create_symlink_for_static_paths( $versionName ) if !$REGISTER_FLAG;
    }

    if ( $NO_CHROOT_FLAG
        && ( $needInstall || grep (/(?:configure|build)/, @MAKE_TARGETS ) )
    ) {
        psw_uninstall_php_build_dependency_package( $versionName );
    }
}

sub psw_register_php_versions_in_phpswitcher_plugin
{
    iMSCP::Bootstrapper->getInstance()->lock();

    print output(
        'Registering PHP versions in the PhpSwitcher plugin...', 'info'
    );

    my $dbh = iMSCP::Database->factory();
    my $dbi = $dbh->getRawDb();
    my ( @toregister, @toupdate );

    local $@;
    eval {
        local $dbi->{'RaiseError'} = 1;

        my $row = $dbi->selectrow_hashref(
            "
                SELECT `plugin_status`, `plugin_error`
                FROM `plugin`
                WHERE `plugin_name` = 'PhpSwitcher'
            "
        );
        unless ( $row->{'plugin_status'} eq 'enabled'
            && !defined $row->{'plugin_error'}
        ) {
            print output( <<"EOF", 'warn' );
Couldn't register the PHP versions in the PhpSwitcher plugin when it is not activated, or when it is in error state.

Please check the plugin status by connecting to the i-MSCP administration interface.
EOF
            return;
        }

        for my $versionName ( @VERSION_NAMES ) {
            my ( $isPackaged, $prefix );

            if ( $PACKAGED_FLAG
                && psw_is_packaged_php_version( $versionName )
            ) {
                $isPackaged = 1;
                $prefix = '/usr'
            } elsif ( $PACKAGED_ONLY_FLAG ) {
                print output( sprintf(
                    "The packaged PHP %s version hasn't been found, or one of its requirements isn't meet (unmet dependencies), and the --packaged-only flag is set. Skipping...",
                    $versionName
                ), 'info' );
                next;
            } elsif ( psw_is_compiled_php_version( $versionName ) ) {
                $prefix = File::Spec->catfile(
                    $NO_STATIC_PATHS
                        ? $INSTALLATION_DIRECTORY : $STATIC_PATHS_BASE_DIR,
                    "php$versionName"
                );
            } elsif ( $PACKAGED_FLAG ) {
                print output( sprintf(
                    "None of packaged or compiled PHP %s versions has been found... Skipping.",
                    $versionName
                ), 'info' );
                next;
            } else {
                print output( sprintf(
                    "The compiled PHP %s version hasn't been found. Skipping...",
                    $versionName
                ), 'info' );
                next;
            }

            my $isDefaultPhpVersion = psw_is_default_php_version( $versionName );

            if ( $isDefaultPhpVersion && !$isPackaged ) {
                # FIXME: Why not?
                print output( sprintf(
                    "Default PHP %s version cannot be replaced by the compiled PHP %s version. Skipping...",
                    $versionName,
                    $versionName
                ), 'warn' );
                next;
            }

            unless( $isPackaged ) {
                psw_create_symlink_for_static_paths( $versionName );
            }

            my (
                $pearDir, $fcgiBinary, $fpmBinary, $fpmConfigFile, $fpmPoolDir
            ) = $isPackaged ? (
                "$prefix/share/php",
                "$prefix/bin/php-cgi$versionName",
                "$prefix/sbin/php-fpm$versionName",
                "/etc/php/$versionName/fpm/php-fpm.conf",
                "/etc/php/$versionName/fpm/pool.d", 1
            ) : (
                "$prefix/share/pear",
                "$prefix/bin/php-cgi",
                "$prefix/sbin/psw$versionName-fpm",
                "$prefix/etc/php-fpm.conf",
                "$prefix/etc/php-fpm.d", 0
            );

            print output( sprintf( <<"EOF",
Registering the %s PHP %s version with data:

 - PEAR directory path         : %s
 - FastCGI binary path         : %s
 - FPM binary path             : %s
 - FPM configuration file path : %s
 - FPM pool directory path     : %s
EOF
                $isPackaged ? 'packaged' : 'compiled', $versionName, $pearDir,
                $fcgiBinary, $fpmBinary, $fpmConfigFile,
                $fpmPoolDir
            ), 'info' );

            my $ret = $dbi->do(
                "
                    INSERT INTO `$DB_TABLE` (
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
                        null, ?, ?, ?, ?, ?, ?, ?, ?, 'toadd'
                    ) ON DUPLICATE KEY UPDATE
                        `version_version` = null,
                        `version_name` = ?,
                        `version_pear_directory_path` = ?,
                        `version_cgi_binary_path` = ?,
                        `version_fpm_binary_path` = ?,
                        `version_fpm_config_file_path` = ?,
                        `version_fpm_pool_directory_path` = ?,
                        `version_is_packaged` = ?,
                        `version_is_default` = ?,
                        `version_status` = IF(`version_status` <> 'toadd', 'tochange', 'toadd')
                ",
                undef,
                $versionName, $pearDir, $fcgiBinary, $fpmBinary, $fpmConfigFile,
                $fpmPoolDir, $isPackaged, $isDefaultPhpVersion,
                $versionName, $pearDir, $fcgiBinary, $fpmBinary, $fpmConfigFile,
                $fpmPoolDir, $isPackaged, $isDefaultPhpVersion
            );
            $ret > 1
                ? push @toupdate, $versionName . ( $isPackaged
                    ? ' (Packaged)' : ' (Compiled)'
                )
                : push @toregister, $versionName . ( $isPackaged
                    ? ' (Packaged)' : ' (Compiled)'
                );
        }

        if ( @toregister ) {
            print output( sprintf(
                "PHP versions scheduled for registration in the PhpSwitcher plugin:\n%s",
                '  - PHP ' . join( "\n  - PHP ", @toregister )
            ), 'ok' );
        }

        if ( @toupdate ) {
            print output( sprintf(
                "PHP versions scheduled for update:\n%s",
                '  - PHP ' . join( "\n  - PHP ", @toupdate )
            ), 'ok' );
        }

        return unless @toregister || @toupdate;

        print output(
            "Processing of PHP versions in progress. Please be patient..." ,
            'info'
        );

        iMSCP::DbTasksProcessor
            ->getInstance( mode => 'backend' )
            ->processDbTasks();

        print output( "PHP versions were processed." , 'ok' );
    };
    if ( $@ ) {
        die( sprintf(
            'An error occurred wile registering PHP versions: %s', $@
        ));
    }

    iMSCP::Bootstrapper->getInstance()->unlock();
}

sub psw_install_php_build_dependencies
{
    my ( $versionName ) = @_;

    print output( sprintf(
        'Installing PHP %s build dependencies...', $versionName
    ), 'info' );

    defined( my $controlFileC = iMSCP::File->new(
        filename => dirname( __FILE__ ) . '/dependencies/build/'
            . psw_guess_distribution() . '/control'
    )->get() ) or die( sprintf(
        "Couldn't get control template file for the PHP %s build dependency package: %s",
        $versionName,
        getMessageByType( 'error', { amount => 1, remove => 1 } )
    ));

    $controlFileC = process( { PHP_VERSION => $versionName }, $controlFileC );

    my $tmpDir = File::Temp->newdir( '.psw-tmpdir-XXXXXX', TMPDIR => 1 );

    local $CWD = $tmpDir->dirname();

    my $controlFile = iMSCP::File->new( filename => './control' );
    $controlFile->set( $controlFileC );
    undef $controlFileC;
    $controlFile->save() == 0 or die( sprintf(
        "Couldn't write the control file for the PHP %s build dependency package: %s",
        $versionName,
        getMessageByType( 'error', { amount => 1, remove => 1 } )
    ));
    undef $controlFile;

    my $stderr = '';
    executeNoWait(
        [
            '/usr/bin/mk-build-deps', '--install',
            '--tool', '/usr/bin/apt-get -y --auto-remove '
            . '--no-install-recommends -o Debug::pkgProblemResolver=yes',
            './control'
        ],
        undef,
        sub { $stderr .= $_[0]; }
    ) == 0 or die( sprintf(
        'An error occurred while installing the PHP %s build dependency package: %s',
        $versionName,
        $stderr || 'Unknown error'
    ));
}

sub psw_uninstall_php_build_dependency_package
{
    my ( $versionName ) = @_;

    print output( sprintf(
        'Uninstalling the PHP %s build dependency package...', $versionName
    ), 'info' );

    my $stderr = '';
    executeNoWait(
        [
            '/usr/bin/apt-get', 'purge', '-y', '--auto-remove',
            "imscp-psw-php$versionName-build-deps"
        ],
        undef,
        sub { $stderr .= $_[0]; }
    ) == 0 or die( sprintf(
        'An error occurred while uninstalling PHP %s build dependencies: %s',
        $versionName,
        $stderr || 'Unknown error'
    ));
}

sub psw_setup_php_build_environment
{
    my ( $minorv ) = @_;

    return 0 unless $NEED_SETUP_PHP_BUILD_ENVIRONMENT;

    $NEED_SETUP_PHP_BUILD_ENVIRONMENT = 0;

    print output( 'Setup PHP build environment...', 'info' );

    my $phpCompilerDir = dirname( __FILE__ );
    my $distributorID = psw_guess_distributor_id();
    my $distribution = psw_guess_distribution();
    chomp( my $architecture =
        `/usr/bin/dpkg --print-architecture 2> /dev/null`
    );
    my $hookDir = "$phpCompilerDir/pbuilder/$distributorID/hook.d";
    my ( $stdout, $stderr );

    # Fix pbuilder warning due to missing .pbuilderrc file
    iMSCP::File->new( filename => '/root/.pbuilderrc' )->save() == 0 or die(
        getMessageByType( 'error', { amount => 1, remove => 1 } )
    );

    # Create symlink for debootstrap script if needed
    unless ( -l "/usr/share/debootstrap/scripts/$distribution" ) {
        local $CWD = '/usr/share/debootstrap/scripts';
        my $oldfile;

        if ( $distributorID eq 'Debian' ) {
            $oldfile = 'sid';
        } elsif ( $distributorID eq 'Ubuntu' ) {
            $oldfile = 'gutsy';
        } else {
            unless (
                -f "$phpCompilerDir/pbuilder/$distributorID/debootstrap/scripts/ceres"
            ) {
                iMSCP::File->new( filename =>
                    "$phpCompilerDir/pbuilder/$distributorID/debootstrap/scripts/ceres"
                )->copyFile(
                    "/usr/share/debootstrap/scripts/$distribution",
                    { preserve => 'no' }
                ) == 0 or die( sprintf(
                    "Couldn't copy debootstrap script for the %s distribution: %s",
                    $distribution,
                    getMessageByType( 'error', { amount => 1, remove => 1 } )
                ));
            }

            $oldfile = 'ceres';
        }

        symlink( $oldfile, $distribution ) or die( sprintf(
            "Couldn't create symlink (%s -> %s) for debootstrap script.",
            $oldfile,
            $distribution
        ));
    }

    # Make sure hooks are executable
    execute( "/bin/chmod -R 0750 $hookDir/*", \$stdout, \$stderr ) == 0 or die(
        sprintf( "Couldn't set execution mode on pbuilder hooks: %s",
            $stderr || 'Unknown error'
        )
    );

    @ENV{qw/ DIST ARCH ARCHITECTURE PSW_COMPILER_ROOT_DIR PSW_VERSION /} = (
        $distribution, $architecture, $architecture, $phpCompilerDir, $minorv
    );

    my $basePath = ( length $ENV{'PSW_PBUILDER_BASEPATH_ROOT_DIR'}
        && -d $ENV{'PSW_PBUILDER_BASEPATH_ROOT_DIR'}
        ? $ENV{'PSW_PBUILDER_BASEPATH_ROOT_DIR'} : '/var/cache/pbuilder'
    ) . "/psw-@{ [ lc $distributorID ] }-$distribution.cow";

    if ( -d $basePath && $ENV{'PSW_SKIP_CHROOT_UPDATE'} ) {
        return;
    }

    executeNoWait(
        [
            '/usr/sbin/cowbuilder',
            ( !-d _
                ? (
                    '--create',
                    '--distribution', $distribution,
                    '--architecture', $architecture
                )
                : ( '--update', '--override-config', '--no-cowdancer-update' ),
            ),
            '--basepath', $basePath,
            '--configfile', "$phpCompilerDir/pbuilder/$distributorID/.pbuilderrc",
            '--hookdir', $hookDir
        ],
        undef,
        sub { $stderr .= $_[0]; }
    ) == 0 or die( sprintf(
        'An error occurred while setup of PHP build environment: %s',
        $stderr || 'Unknown error'
    ));
}

sub psw_install_php_runtime_dependency_package
{
    my ( $versionName ) = @_;

    local $@;
    eval {
        print output( sprintf(
            'Installing PHP %s runtime dependencies...', $versionName
        ), 'info' );

        defined( my $controlFileC = iMSCP::File->new(
            filename => dirname( __FILE__ ) . '/dependencies/runtime/'
                . psw_guess_distribution() . '/control'
        )->get() ) or die( sprintf(
            "Couldn't get control template file for PHP %s runtime dependency package: %s",
            $versionName,
            getMessageByType( 'error', { amount => 1, remove => 1 } )
        ));

        $controlFileC = process(
            { PHP_VERSION => $versionName }, $controlFileC
        );

        my $tmpDir = File::Temp->newdir( '.psw-tmpdir-XXXXXX', TMPDIR => 1 );

        local $CWD = $tmpDir;

        my $controlFile = iMSCP::File->new( filename => './control' );
        $controlFile->set( $controlFileC );
        undef $controlFileC;

        $controlFile->save() == 0 or die( sprintf(
            "Couldn't write control file for PHP %s runtime dependency package: %s",
            $versionName,
            getMessageByType( 'error', { amount => 1, remove => 1 } )
        ));
        undef $controlFile;

        my $stderr = '';
        executeNoWait(
            [ '/usr/bin/equivs-build', './control' ],
            undef,
            sub { $stderr .= $_[0]; }
        ) == 0 or die( $stderr || 'Unknown error' );

        executeNoWait(
            [ '/usr/bin/dpkg', '--unpack', glob '*.deb' ],
            undef,
            sub { $stderr .= $_[0]; }
        ) == 0 or die( $stderr || 'Unknown error' );

        my $rs = executeNoWait(
            [
                '/usr/bin/apt-get', '-y', '--auto-remove',
                '--no-install-recommends',
                '-o', 'Debug::pkgProblemResolver=yes', '-f', 'install'
            ],
            undef,
            sub { $stderr .= $_[0]; }
        );

        if ( $rs ) {
            # Restore the system to previous state, since APT wasn't able to
            # resolve a proper way to get the runtime dependency package
            # installed.
            execute(
                [ '/usr/bin/dpkg', '--remove', glob '*.deb' ], undef, sub {}
            );
            die( $stderr || 'Unknown error' );
        } elsif ( $stderr =~ /\Qremoving imscp-psw-php$versionName-runtime-dependencies\E/i ) {
            die( "Unmet dependencies.\n" );
        }
    };
    if ( $@ ) {
        die( sprintf(
            'An error occurred while installing PHP %s runtime dependency package: %s',
            $versionName,
            $@
        ));
    }
}

sub psw_guess_distribution
{
    CORE::state $distribution //= do {
        $ENV{'DISTRIBUTION'} //= (
            $ENV{'PSW_DISTRIBUTION'} //= $::imscpConfig{'DISTRO_CODENAME'}
        );

        grep ( $_ eq $ENV{'DISTRIBUTION'}, qw/
            devuan_jessie jessie stretch buster bullseye bookworm xenial bionic
            ascii beowulf
        / ) or die( sprintf(
            "An error occurred while guessing distribution: The %s distribution isn't supported.",
            $ENV{'DISTRIBUTION'}
        ));

        $ENV{'DISTRIBUTION'} =~ s/^devuan_//r;
    };
    
    $distribution;
}

sub psw_guess_distributor_id
{
    CORE::state $distributorID;

    return $distributorID if length $distributorID;

    my $distribution = psw_guess_distribution();

    if ( index( $ENV{'PSW_DISTRIBUTION'}, 'devuan_' ) == 0
        || $distribution eq 'ascii'
    ) {
        return $distributorID = $ENV{'DISTRIBUTOR_ID'} = 'Devuan';
    }

    if ( grep (
        $_ eq $distribution, qw/ jessie stretch buster bullseye bookworm /
    ) ) {
        return $distributorID = $ENV{'DISTRIBUTOR_ID'} = 'Debian'
    }

    $distributorID = $ENV{'DISTRIBUTOR_ID'} = 'Ubuntu';
}

sub psw_is_packaged_php_version
{
    my ( $versionName ) = @_;

    CORE::state $packagedPhpVersions = {};

    $packagedPhpVersions->{$versionName} //= do {
        my @cmdArgv;

        for my $filePath (
            "/usr/bin/php-cgi$versionName",
            "/usr/sbin/php-fpm$versionName",
            '/usr/share/php/PEAR.php'
        ) {
            push @cmdArgv, escapeShell( $filePath );
        }

        execute( "/usr/bin/dpkg-query -S @cmdArgv > /dev/null 2>&1" ) == 0;
    };
}

sub psw_is_compiled_php_version
{
    my ( $versionName ) = @_;

    my $prefix = File::Spec->catfile(
        $INSTALLATION_DIRECTORY, "php$versionName"
    );

    for my $dir ( $prefix, "$prefix/share/pear", "$prefix/etc/php-fpm.d" ) {
        return 0 unless -d $dir;
    }

    for my $file ( "$prefix/share/pear/PEAR.php", "$prefix/etc/php-fpm.conf" ) {
        return 0 unless -f $file;
    }

    for my $executable (
        "$prefix/bin/php-cgi", "$prefix/sbin/psw$versionName-fpm"
    ) {
        return 0 unless -x $executable;
    }

    1;
}

sub psw_is_default_php_version
{
    my ( $versionName ) = @_;

    return 0 unless Servers::httpd->factory()
        ->{'phpConfig'}->{'PHP_VERSION'} eq $versionName;

    1;
}

sub psw_create_symlink_for_static_paths
{
    my ( $versionName ) = @_;

    return if $STATIC_PATHS_BASE_DIR eq $INSTALLATION_DIRECTORY
        || !-d "$INSTALLATION_DIRECTORY/php$versionName";

    if ( $NO_STATIC_PATHS ) {
        eval { iMSCP::Dir->new( dirname => $STATIC_PATHS_BASE_DIR )->remove(); };
        !$@ or die( sprintf(
            "Couldn't remove base directory for static paths: %s", $@
        ));
        return;
    }

    eval { iMSCP::Dir->new( dirname => $STATIC_PATHS_BASE_DIR )->make(); };
    !$@ or die( sprintf(
        "Couldn't create base directory for static paths: %s", $@
    ));

    if ( -l "$STATIC_PATHS_BASE_DIR/php$versionName" ) {
        iMSCP::File->new(
            filename => "$STATIC_PATHS_BASE_DIR/php$versionName"
        )->delFile() == 0 or die( sprintf(
            "Couldn't remove previous symlink for static paths: %s",
            getMessageByType( 'error', { acount => 1, remove => 1 } )
        ));
    }

    symlink( File::Spec->abs2rel(
        "$INSTALLATION_DIRECTORY/php$versionName", $STATIC_PATHS_BASE_DIR
    ), "$STATIC_PATHS_BASE_DIR/php$versionName" ) or die( sprintf(
        "Couldn't create symlink for static paths: %s", $!
    ));
}

1;
__END__
