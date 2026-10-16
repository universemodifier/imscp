# Update errata

## Glossary

In the documentation below, the following variables are used:

- %version%    : One of available PHP version such as  5.6, 7.0 or 7.1 ...
- %ymd%*       : The date of the day such as 20190906
- %installdir% : Installation directory for PHP versions such as
                 /opt/phpswitcher/20190908

## Update to version 5.0.0

- Support for i-MSCP versions older than 1.5.3 has been dropped
- Support for Ubuntu Trusty Thar (14.04) has been dropped
- Support for both PHP 4.4 and PHP 5.2 has been dropped.
- Support for PHP 7.2, 7.3, 7.4 has been added.

### php_compiler.pl script

#### Command line arguments

In the previous versions, the `all` argument was required to tell the
`php_compiler.pl` script to process all supported PHP versions. This argument
has been removed. From now on, if you don't pass any PHP version on the command
line, all PHP versions will be assumed. To sumarize:

```shell
# perl /var/www/imscp/gui/plugins/PhpSwitcher/PhpCompiler/php_compiler.pl
```

All PHP versions will be assumed.

``` shell
# perl /var/www/imscp/gui/plugins/PhpSwitcher/PhpCompiler/php_compiler.pl 7.0
```

Only the PHP 7.0 version will be assumed.

``` shell
# perl /var/www/imscp/gui/plugins/PhpSwitcher/PhpCompiler/php_compiler.pl 7.0 7.1 7.2 7.3 7.4
```

Only the PHP 7.0, 7.1, 7.2, 7.3, and 7.4 versions will be assumed.

#### Build environment

The PHP versions are now configured and compiled in a chroot environment by
default, to avoid installing all PHP build dependencies on production system.
You can switch back to the historical behavior (not recommended unless in
specific environments), by passing the `--no-chroot` option to the
`php_compiler.pl` script.

#### Static paths

For convenience, the `php_compiler.pl` script now creates symlinks to the
installation directories of various PHP versions, which allows the sysadmin
to access the PHP binaries always by the same paths (e.g. in CRONTAB(5) files).

These symlinks are created in the `/opt/phpswitcher/static` directory, either at
the installation stage, or at the registration stage. If you do not want these
symlinks, you can pass the `--no-static-paths` option to the `php_compiler.pl`
script.

Note that when the symlinks are available, they will be used for registration
process in place of the default paths.

#### OpenSSL 1.1.x support

Support for OpenSSL 1.1.x has been added to older PHP versions: 5.3, 5.4, 5.5

#### Automatic registration of PHP versions

The `--auto-setup` command line option has been renamed to `--register`.

##### Packaged PHP versions

The `php_compiler.pl` script now make possible to automatically register
packaged PHP versions in the PhpSwitcher plugin. Packaged PHP versions are
either those provided by Debian PHP team, or Ondřej Surý repositories. To
register the packaged PHP versions, you need to execute the following command:

```shell
# perl /var/www/imscp/gui/plugins/PhpSwitcher/PhpCompiler/php_compiler.pl --register --packaged
```

When the `--packaged` option is passed-in, the PHP compiler will favor
registration of packaged PHP versions rather than compiled ones. In other words,
for a given PHP version, the PHP compiler will fallback to a compiled PHP
version only if there is no packaged PHP version available.

If you want only work with packaged PHP versions, you can also pass the
`--packaged-only` option:

```shell
# perl /var/www/imscp/gui/plugins/PhpSwitcher/PhpCompiler/php_compiler.pl --register --packaged --packaged-only
```

With this option, only the packaged PHP versions will be considered, regardless
of their availalibity. If no packaged PHP version is available, nothing will
happend, that is, no fallback to compiled PHP version will be involved.

You can of course still specify the PHP versions on which you want to operate
on, and you can also change the default directory, where the PHP compiler is
looking for the compiled PHP versions, by passing the `--install-dir` option.
For instance:

```shell
# perl /var/www/imscp/gui/plugins/PhpSwitcher/PhpCompiler/php_compiler.pl --register --packaged --install-dir /opt/my/install/directory 7.1 7.3 7.4
```

Note that for a packaged PHP version, the plugin backend will skip generation of
most configuration files as those are already provided by the package. You need
also remember that for a packaged PHP version, the FPM service name is
`php%version%-fpm` instead of `psw%version%-fpm`.

Finally, you need keep in mind that for the PHP compiler, the packaged PHP
versions are considered only when all requirements are met, that is, when for a
given PHP version, the CGI sapi, FPM sapi, and the PEAR distribution are all
installed on the system. For instance, if you want to register the PHP 7.3
packaged version, you must first make sure that all required distribution
packages are installed:

```shell
# apt-get update
# apt-get install php7.3-cli php7.3-cgi php7.3-fpm php-pear
```

## Update to version 3.0.0

### --auto-setup command line option (PHP compiler)

It is now possible to automatically register the PHP versions in the
PhpSwitcher plugin. For doing so, you must execute the PHP compiler by pasing
the `--auto-setup` option. For instance:

```shell
# perl /var/www/imscp/gui/plugins/PhpSwitcher/PhpCompiler/php_compiler.pl --auto-setup all
```

It is also possible to ask the PHP compiler to register the PHP versions found
in a specific directory. For instance:

```shell
# perl /var/www/imscp/gui/plugins/PhpSwitcher/PhpCompiler/php_compiler.pl --auto-setup --install-dir %installdir%
```

### Default installation directory (PHP compiler)

Default installation directory for PHP versions has been changed from
`/opt/phpswitcher` to `/opt/phpswitcher/%ymd%`.

### SSL support for PHP >= 4.4 but < 5.6 (PHP compiler)

For systems on which OpenSSL library is greater or equal to 1.1.0, PHP versions
greater than 4.4 but older than 5.6 are now built against a self-compiled
OpenSSL library (1.0.2k).

## Update to version 2.2.1

## PHP-FPM binary/script path basenames and service names

To be consistent with PHP versions provided by Debian/Ubuntu, PHP-FPM path
basenames and service names were renamed from `psw-%version%...` to
`psw%version%...`. For instance: `psw-7.0-fpm` to `psw7.0-fpm`.

## Update to version 2.0.0

First, it is highly recommended to read the README file carefully to learn more
about this new version. Many things were changed, notably the way additional PHP
versions are setup.

### PHP-FPM support

This new version add support for the PHP-FPM Apache2 i-MSCP httpd server
implementation. Before, it was only possible to use this plugin with the Fcgid
Apache2 i-MSCP httpd server implementation.

If you already use that plugin and want switch to the PHP-FPM Apache2 i-MSCP
httpd server implementation, you must in order:

 - Update the plugin as usually but do not recompile your PHP versions yet
 - Run the i-MSCP installer (perl imscp-autoinstall -dar httpd) to switch to the
   PHP-FPM Apache2 i-MSCP httpd server implementation
 - Recompile your PHP versions (this is needed to add PHP-FPM support and update
   to the latest upstream versions)
 - Update PHP version settings through the PhpSwitcher administration interface
 - Reactivate your PHP versions through the PhpSwitcher administration interface

### PHP compiler changes

PHP versions provided by the PHP compiler are now always compiled with the cgi,
cli and fpm SAPIs, whatever the i-MSCP httpd server implementation in use.

Note that in PHP 5.3 case, the cgi and fpm SAPIs are configured and built
separately.

You must also note that when using the PHP-FPM Apache2 i-MSCP httpd server
implementation, only the following PHP versions are available:

    `5.3`, `5.4`, `5.5`, `5.6`, `7.0` and `7.1`

This is due to the fact that older versions don't provide the fpm SAPI.

## Update to version 1.0.0

### New features

#### PHP compiler

A PHP compiler has been added. This is a Perl script which downloads,
configures, compiles and installs one or many PHP versions in one step. That is
now the recommended way to install or update PHP versions for use with this
plugin.

#### Per user, per domain and per site PHP version

It is now possible to setup a specific PHP version either per user, per domain
or per site, depending on the PHP INI level in use. If you want to allow your
customers to set per site PHP version, you must ensure that the PHP INI level of
the Fcgid httpd implementation is set to per_site. You can reconfigure the PHP
INI level by running the following command:

```shell
# perl /var/www/imscp/engine/setup/imscp-reconfigure -dar php
```

#### PHP info (phpinfo)

Links to phpinfo were added in the client interface. This allows your customers
to get information about the PHP version currently in use for their sites. PHP
info are provided through static phpinfo files which are generated when you add
or change a PHP version, or when you explicitly ask to re-generate them.

You can always disable this feature by editing the plugin configuration file,
and by updating the plugin list through the plugin management interface.

Note: If you disable or enable a PHP module, do not forget to re-generate the
static phpinfo file through the PhpSwitcher admin interface.

### Removed features

#### Memcached support

Memcached support has been removed due to security issues (possible cache
poisoning). Thus, the backend side of the plugin has been fully rewritten to
improve overall performances.

#### PHP version parameters

It is no longer possible to setup a specific PHP configuration directory for the
PHP ini files. The directory is now defined by the Fcgid i-MSCP httpd server
implementation (/var/www/fcgi by default).
