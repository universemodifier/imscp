#!/bin/sh
# i-MSCP PhpSwitcher plugin
#
# @author        Laurent Declercq <l.declercq@nuxwin.com>
# @copyright (C) 2014-2019 Laurent Declercq <l.declercq@nuxwin.com>
# @license       i-MSCP License <https://www.i-mscp.net/license-agreement.html>

# Wrapper for execution of MAKE(1) inside chroot environment.

/usr/bin/make "$@"
