# i-MSCP LetsEncrypt plugin
#
# @author Laurent Declercq <l.declercq@nuxwin.com>
# @copyright (C) 2016-2018 Laurent Declercq <l.declercq@nuxwin.com>
# @license i-MSCP License <http://www.i-mscp.net/license-agreement.html>

use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin, "$FindBin::Bin/../backend", "$FindBin::Bin/../../../../engine/PerlLib",
    "$FindBin::Bin/../../../../engine/PerlVendor";
use Test::More;
use Symbol 'delete_package';
use iMSCP::Bootstrapper;

$ENV{'LANG'} = 'C.UTF-8';
$ENV{'PATH'} = '/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin';

iMSCP::Bootstrapper->getInstance()->boot( {
    mode            => 'testing',
    nolock          => 'yes',
    norequirements  => 'yes',
    config_readonly => 'yes',
    #nokeys          => 'yes',
    #nodatabase      => 'yes'
} );

chdir( "$FindBin::Bin/Plugin" ) or BAIL_OUT( sprintf( "Could not change dir to %s: %s", "$FindBin::Bin/Plugin", $! ));

for ( <*.pm> ) {
    my $package = 'Plugin::' . substr( $_, 0, -3 );

    unless ( eval "require $package" ) {
        BAIL_OUT sprintf( "Couldn't run %s unit tests: %s", $package, $@ );
        last;
    }

    if ( my $function = $package->can( 'runUnitTests' ) ) {
        diag "\nRunning unit tests from $package package...\n\n";
        subtest "$package unit tests", sub { $function->( "$FindBin::Bin/TestAsset" ) };
        delete_package $package; # Mitigates memory consumption by wiping out the whole package namespace
        next;
    }

    fail sprintf( '%s::runUnitTests() not implemented', $package );
}

done_testing;

1;
__END__
