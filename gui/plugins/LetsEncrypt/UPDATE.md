# Update to version 3.4.0

## Plugin configuration parameters

## Subject alternative names (DNS names)

Customers can now add up to 100 DNS names to their SSL certificates without
having to rely on system administrator. By default their are no restrictions
made on DNS names apart domain name validation.

System administrator can enable strict validation for DNS names by setting the
value of the  `dns_names_strict_validation` plugin configuration parameter to
`TRUE`. In such a case, customers are only allowed to add DNS names that are
part of the domain for which the SSL certificate is or has been issued.

## Alternative URLs

The `include_altnames` plugin configuration parameter for addition of the
domains bound to thealternative URLs as subject alternative name of SSL
certificate has been removed. Customers can now add subject alternative
names in their SSL certificates.

# Update to version 3.3.0

## Internal implementation details

Starting with this new version, the plugin will not longer make use of the
certbot-auto script outside of installation/update process. It will now call
the certbot client directly. Following this change, the `certbot_self_upgrade`
plugin configuration parameter has been removed because it is useless in
certbot client context.

# Update to version 3.2.0

### certbot-auto self-upgrade

Self upgrade of certbot-auto has been disabled by default to ensure
compatibility with the plugin. Indeed, any changes made in a newest certbot
client version could breaks the plugin.

Be aware that if you set the `certbot_self_upgrade` configuration parameter to
TRUE in the plugin configuration file, no support will be given by us in case
something goes wrong with your installation.

### Support for Devuan Jessie 1.0 RC

Devuan Jessie is not officially supported by certbot-auto. However, because
Devuan Jessie is almost identical to Debian Jessie it has been possible to add
support for it by patching certbot-auto. Note that to make this to work, you
must not set the `certbot_self_upgrade` configuration parameter to TRUE in the
plugin configuration file. If you do so, the changes made will be lost.

# Update to version 3.1.0

## DNS checks

DNS checks for subject alternative names were removed. They were too much time
consuming.

## Test for the `/.well-known/acme-challenge/` URL path reachability
 
A new routine has been added which performs a http reachability test for the
`/.well-known/acme-challenge/` URL path, this for each subject alternative
name. This new test allows to warn the administrator or customers when the
`/.well-known/acme-challenge/` URL path is not reachable, and avoids useless
execution of the Certbot client which anyway would fails.

Mostly, when an error is raised following a http reachability test, this means
either that there is a DNS problem, or that there is an Apache2 rewrite rule
somewhere that rewrites the path to an unexpected location.

Bear in mind that there are still cases where the test succeed even if DNS are
not properly set. For instance if you're enabling SSL for the server hostname
(mainly when enabling SSL for FTP, IMAP/POP and SMTP services) and that there is
no valid DNS record for it, the test will succeed but Certbot will still fails.
This is due to the fact that the server hostname is resolved locally, using
entries from the /etc/hosts file. This is also true for any name resolvable by the
local DNS server if one is present.

# Update to version 3.0.0

## IDNs support (Internationalized Domain Names)

IDNs are now fully supported. Usage of the Certbot client development version
is no longer required.

## Let's Encrypt Fake LE Root X1 root certificate

The Let's Encrypt `Fake LE Root X1'` root certificate is now added into the
list of trusted certificates (OS side). Doing this allows to make i-MSCP happy
with SSL certificates that are issued by the Let's Encrypt staging environment.

Only developers should have an interest for that change.

## Subject alternative names (control panel and services SSL certificates)

The administrator can now add up-to 100 subject alternative names (SANs) in
both control panel and services SSL certficates. This new feature allows the
administrator to expand/shrink these SSL certificates in easy way.

Note that for performance reasons, no pre DNS checks are made on the provided
subject alternative names. If one of the provided name cannot be resolved due
to missing DNS record, it will be not added in the SSL certificate (ignored).

# Update to version 2.0.0

## Cron tasks for pending and renewal tasks

Cron tasks for both pending tasks and renewal tasks were not backward
compatible with i-MSCP versions prior 1.3.6, resulting in many processes
awaiting for lock. If you're running an i-MSCP version older than 1.3.6, you
should check the process table. You can refer to the following thread on our
forums for more details:
 
 https://i-mscp.net/index.php/Thread/15265-Change-PW-of-mail-user-doesn-t-work

## Let's Encrypt SSL certificates for the customers

Due to a major issue found in previous versions, the status of all customer
entries in the letsencrypt database table will be updated to 'torenew'. Note
that the plugin will process SSL certificates that belong to these entries only
when really necessary, regardless of the status set.

## Let's Encrypt SSL certificates for the control panel and services

Due to major issues found in previous versions, the entries for the control
panel and/or services will be automatically removed from the `letsencrypt`
database table during update, meaning that you'll be be forced to re-enable SSL
for them if needed.

The link for accessing the administrator's interface for Let's Encrypt has been
moved in the system tools page.

# Update to version 1.3.0

## Let's Encrypt SSL certificates for the control panel and services

The plugin is now able to handle issuance of SSL certificates for the control
panel and/or services. To enable Let's Encrypt for the control panel and/or
services you must in order:

- Enable SSL on i-MSCP side for the control panel and/or services, by choosing
  the `self-signed` SSL certificate option
- Connect as administrator to the control panel
- Activate Let's Encrypt for the control panel and/or services through the
  administrator's Let's Encrypt interface.

The link for accessing the administrator's Let's Encrypt interface is available
in the settings page.

Note that it is important to not disable this plugin when updating or
reconfiguring i-MSCP because there is an event listener that replace the
default SSL certificates by the Let's Encrypt SSL certificates. If the
LetsEncrypt plugin is disabled, the event listener will not be triggered and
so, the SSL certificates won't be replaced.

Be aware that this feature is still experimental.

### Regarding SSL certificate for the control panel

Note that after enabling Let's Encrypt for the control panel, you may have to
close and re-open your browser. Indeed, in some cases, the newly created SSL
certificate is not loaded after a simple page refresh.

### Note for PanelRedirect plugin users

If you use the `PanelRedirect plugin`, you must ensure that you have a version
greater or equal to `1.1.5`, else, the domain validations will fail.

## SANs for alternative URL

Support for alternative URLs has been added. You can enable it by setting the
`include_altnames` configuration parameter to `true` in the plugin
configuration file. Once done, don't forget to trigger a plugin list update.

Before enabling support for alternative URLs, be sure that your DNS server can
resolve names for them. If you use an external DNS server, this is generally
achieved by adding a wildcard DNS resource record such as:

    *.<panel.domain.tld>. IN A <server.ip>

where `<panel.domain.tld>` is the domain used for accessing the i-MSCP control
panel and `<server.ip>`, the primary IP address of the i-MSCP server.

Be aware that this parameters acts only for new SSL certificate issuance.

### Warning regarding this feature

Due to the current Let's Encrypt rate limits, it is not recommended to enable
this feature. Indeed, each SSL certificate issuance for which a SAN is added
for an alternative URL will hits the `Certificate per Registered Domain` limit
(20 per week) for the control panel domain. This explain why this feature is
turned off by default.

Note that alternative URLs as provided by i-MSCP are meant to allow the
customer to access his domain for DNS propagation time. These URLs should not
be exposed publicly.

# Update to version 1.2.0

## IDNs support (Internationalied Domain Names)

The support for IDNs has been added However, note that the version of the
certbot client that adds support for the IDNs has not been published yet
(at least at time when this new plugin version has been released).

If you want to enable support for IDNs, you must use the development version of
the certbot client by setting the value of the `certbot_version` parameter to
`develop` in the plugin configuration file. Once done, don't forget to trigger
a plugin list update through the i-MSCP plugin management interface.

Note that when the certbot client version that supports IDNs names will be
released, the usage of the development version of the certbot client will no
longer be mandatory.

Be aware that using the development version of the certbot client can lead to
other issues. This is the development version and as such, stability of this
version cannot be guaranteed by us. You're warned.

## WWW prefix for domains and subdomains

In earlier versions, the `www` prefix was always included when issuing or
renewing an SSL certificates, whatever the domain type. From now, the inclusion
of this prefix is optional. By default, the inclusion of the `www` prefix is
pre-checked for the domains, while for the subdomains, it is unchecked.
