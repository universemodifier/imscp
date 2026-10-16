#!/usr/bin/make -f
#
# i-MSCP PhpSwitcher plugin
#
# @author Laurent Declercq <l.declercq@nuxwin.com>
# @copyright (C) 2014-2019 Laurent Declercq <l.declercq@nuxwin.com>
# @license i-MSCP License <https://www.i-mscp.net/license-agreement.html>

# Enable dpkg build flags
DPKG_EXPORT_BUILDFLAGS  = 1
include /usr/share/dpkg/buildflags.mk

DEB_HOST_GNU_TYPE       ?= $(shell dpkg-architecture -qDEB_HOST_GNU_TYPE)
DEB_BUILD_GNU_TYPE      ?= $(shell dpkg-architecture -qDEB_BUILD_GNU_TYPE)
DEB_HOST_ARCH           ?= $(shell dpkg-architecture -qDEB_HOST_ARCH)
DEB_HOST_ARCH_OS        ?= $(shell dpkg-architecture -qDEB_HOST_ARCH_OS)
DEB_HOST_MULTIARCH      ?= $(shell dpkg-architecture -qDEB_HOST_MULTIARCH)
export DEB_HOST_MULTIARCH

SANE_ARCHS              := amd64 i386 arm64

PHP_NAME_VERSION        := $(shell echo $(CURDIR) | sed -e "s/.*\/php-\([0-9]\{1,\}\.[0-9]\{1,\}\)\.[0-9]\{1,\}\(\(alpha\|beta\|RC\)[0-9]\{1,\}\)\?$$/\1/")

# Enable ZTS support if needed
ifeq (zts,$(findstring zts,$(BUILD_OPTIONS)))
$(info Enabling ZTS support)
CONFIGURE_ZTS           := --enable-maintainer-zts
endif

PATCH_TARGETS           := patch-stamp
CONFIGURE_TARGETS       := $(addprefix configure-, $(addsuffix -stamp, $(PHP_NAME_VERSION)))
BUILD_TARGETS           := $(addprefix build-, $(addsuffix -stamp, $(PHP_NAME_VERSION)))
INSTALL_TARGETS         := $(addprefix install-, $(addsuffix -stamp, $(PHP_NAME_VERSION)))

ifeq (5.3,$(PHP_NAME_VERSION))
CONFIGURE_TARGETS       += configure-5.3-fpm-stamp
BUILD_TARGETS           += build-5.3-fpm-stamp
INSTALL_TARGETS         += install-5.3-fpm-stamp
endif

ifeq ($(DEB_HOST_ARCH),$(filter $(DEB_HOST_ARCH),amd64 armel armhf i386 ia64 powerpc))
CONFIGURE_DTRACE_ARGS   := --enable-dtrace
else
CONFIGURE_DTRACE_ARGS   := --disable-dtrace
endif

PROG_SENDMAIL           := /usr/sbin/sendmail

ifeq (,$(findstring noopt,$(BUILD_OPTIONS)))
CFLAGS                  += -O2
else
CFLAGS                  += -O0
endif

CFLAGS                  += -fsigned-char -fno-strict-aliasing
CFLAGS                  += $(shell getconf LFS_CFLAGS)

# Enable IEEE-conformant floating point math on alphas (not the default)
ifeq (alpha-linux-gnu,$(DEB_HOST_GNU_TYPE))
CFLAGS                  += -mieee
endif

# Set number of parallel jobs
ifneq (,$(filter parallel=%,$(BUILD_OPTIONS)))
NUMJOBS                 := -j$(patsubst parallel=%,%,$(filter parallel=%,$(BUILD_OPTIONS)))
endif

PREFIX                  ?= /opt/phpswitcher

CONFIGURE_PCRE_JIT :=
ifeq (,$(filter $(DEB_HOST_ARCH),$(SANE_ARCHS)))
CONFIGURE_PCRE_JIT      := --without-pcre-jit
endif

COMMON_CONFIG = \
	--build=$(DEB_BUILD_GNU_TYPE) \
	--host=$(DEB_HOST_GNU_TYPE) \
	--config-cache --cache-file=$(CURDIR)/config.cache \
	--prefix=$(PREFIX)/php$(PHP_NAME_VERSION) \
	--localstatedir=/var \
	--with-config-file-path=$(PREFIX)/php$(PHP_NAME_VERSION)/etc/php \
	--with-config-file-scan-dir=$(PREFIX)/php$(PHP_NAME_VERSION)/etc/php/conf.d \
	--disable-all \
	--disable-debug \
	--disable-option-checking \
	--disable-rpath \
	--disable-static \
	--with-pear \
	--with-pic \
	--with-layout=GNU \
	--enable-filter \
	--with-openssl \
	--with-pcre-regex=/usr \
	--enable-hash \
		--with-mhash=/usr \
	--enable-libxml \
	--with-libxml-dir=/usr \
	--enable-session \
	--with-system-tzdata \
	--with-zlib=/usr \
		--with-zlib-dir=/usr \
	--enable-bcmath=shared \
	--with-bz2=shared,/usr \
	--enable-calendar=shared \
	--enable-ctype=shared \
	--enable-exif=shared \
	--enable-fileinfo=shared \
	--enable-ftp=shared \
		--with-openssl-dir=/usr \
	--with-gettext=shared,/usr \
	--with-iconv=shared \
	--enable-pcntl \
	--enable-pdo=shared \
	--enable-phar=shared \
	--enable-posix=shared \
	--enable-shmop=shared \
	--enable-sockets=shared \
	--enable-sysvmsg=shared \
	--enable-sysvsem=shared \
	--enable-sysvshm=shared \
	--enable-tokenizer=shared \
	--with-curl=shared,/usr \
	--enable-dba=shared \
		--with-db4=/usr \
		--without-gdbm \
		--with-qdbm=/usr \
		--enable-inifile \
		--enable-flatfile \
	--with-enchant=shared,/usr \
	--with-gd=shared,/usr \
		--enable-gd-native-ttf \
		--with-jpeg-dir=/usr \
		--with-xpm-dir=/usr/X11R6 \
		--with-png-dir=/usr \
		--with-freetype-dir=/usr \
		--with-webp-dir=/usr \
	--with-gmp=shared,/usr \
	--with-imap=shared,/usr \
		--with-kerberos \
		--with-imap-ssl=yes \
	--enable-intl=shared \
	--enable-json=shared \
	--with-ldap=shared,/usr \
		--with-ldap-sasl=/usr \
	--enable-mbstring=shared \
		--enable-mbregex \
		--enable-mbregex-backtrack \
	--with-mcrypt=shared,/usr \
	--with-unixODBC=shared,/usr \
		--with-pdo-odbc=shared,unixODBC,/usr \
	--with-pgsql=shared,/usr \
		--with-pdo-pgsql=shared,/usr \
	--with-pspell=shared,/usr \
	--with-libedit=shared,/usr \
	--with-recode=shared,/usr \
	--with-snmp=shared,/usr \
	--enable-soap=shared \
	--with-sqlite3=shared,/usr \
		--with-pdo-sqlite=shared,/usr \
	--with-pdo-dblib=shared,/usr \
		--with-mssql=shared,/usr \
	--with-tidy=shared,/usr \
	--enable-dom=shared \
	--enable-simplexml=shared \
	--enable-wddx=shared \
	--enable-xml \
	--enable-xmlreader=shared \
	--enable-xmlwriter=shared \
	--with-xmlrpc=shared,/usr \
	--with-xsl=shared,/usr \
	--enable-zip=shared \
		--with-libzip=/usr \
	--enable-opcache \
		--enable-opcache-file \
		--enable-huge-code-pages \
	$(CONFIGURE_ZTS) \
	$(CONFIGURE_DTRACE_ARGS) \
	$(CONFIGURE_PCRE_JIT)

# Make use of bundled native MySQL driver (mysqlnd)
MYSQL_CONFIG = \
	--enable-mysqlnd=shared \
		--enable-mysqlnd-compression-support \
	--with-mysqli=shared,mysqlnd \
	--with-pdo-mysql=shared,mysqlnd \
	--with-mysql=shared,mysqlnd

# Compile both interbase and pdo_firebird extensions only if supported
ifneq ($(DEB_HOST_ARCH),$(filter $(DEB_HOST_ARCH),hurd-i386 m68k hppa ppc64))
COMMON_CONFIG           += --with-interbase=shared,/usr --with-pdo-firebird=shared,/usr
endif

5.3_CONFIG              := \
	--enable-cgi --enable-cli --enable-force-cgi-redirect --enable-fastcgi \
	$(COMMON_CONFIG) \
	$(MYSQL_CONFIG) \
	--with-sqlite=shared,/usr
5.3-fpm_CONFIG          := \
	$(5.3_CONFIG) \
	--disable-cgi --disable-cli --enable-fpm \
	--with-fpm-user=www-data --with-fpm-group=www-data
5.4_CONFIG              := \
	--enable-cgi --enable-cli --enable-fpm \
	--enable-force-cgi-redirect --enable-fastcgi \
	--with-fpm-user=www-data --with-fpm-group=www-data \
	$(COMMON_CONFIG) \
	$(MYSQL_CONFIG) \
	--with-sqlite=shared,/usr
5.5_CONFIG              := $(5.4_CONFIG)
5.6_CONFIG              := $(5.5_CONFIG) \
	--disable-phpdbg
7.0_CONFIG              := $(5.6_CONFIG)
7.1_CONFIG              := $(7.0_CONFIG)
7.2_CONFIG              := $(7.1_CONFIG) \
	--with-password-argon2=/usr \
	--with-sodium=shared,/usr
7.3_CONFIG              := $(7.2_CONFIG)
7.4_CONFIG              := $(7.3_CONFIG) \
	--enable-gd=shared,/usr --with-external-gd \
	--with-external-pcre \
	--with-libxml \
	--with-zip=shared \
	--with-ffi=shared \
	--with-gmp=shared

PHP_QUILT_PATCH_DIR     ?= /var/www/imscp/gui/plugins/PhpSwitcher/PhpCompiler/patches/$(PHP_NAME_VERSION)

patch: $(PATCH_TARGETS)
patch-stamp:
	QUILT_PATCHES=$(PHP_QUILT_PATCH_DIR) quilt --quiltrc /dev/null push -a --fuzz 0 || test $$? = 2
	touch patch-stamp

unpatch: $(UNPATCH_TARGETS)
	QUILT_PATCHES=$(PHP_QUILT_PATCH_DIR) quilt --quiltrc /dev/null pop -a -R || test $$? = 2
	rm -rf .pc patch-stamp

prepared: prepared-stamp
prepared-stamp:
	-[ -f ext/ext_skel ] && mv ext/ext_skel ext/ext_skel.in
	./buildconf --force
	touch prepared-stamp

unprepared:
	-[ -f ext/ext_skel.in ] && mv ext/ext_skel.in ext/ext_skel
	rm -rf autom4te.cache
	rm -f $(CURDIR)/config.cache
	rm -f buildmk.stamp prepared-stamp configure

clean: unprepared unpatch
	rm -f $(CONFIGURE_TARGETS)
	rm -f $(BUILD_TARGETS)
	rm -f $(INSTALL_TARGETS)

configure-openssl: configure-openssl-stamp
configure-openssl-stamp: $(PATCH_TARGETS)
	rm -rf $(OPENSSL_INSTALL_DIR)
	rm -rf openssl-build
	cp -rpf $(OPENSSL_SRC_DIR) openssl-build
	cd openssl-build && ./Configure no-shared $(OPENSSL_CONFARGS) debian-$(DEB_HOST_ARCH);
	touch configure-openssl-stamp

configure: $(CONFIGURE_TARGETS)
configure-%-stamp: patch-stamp prepared-stamp
	rm -rf $*-build
	mkdir $*-build
	cd $*-build && CFLAGS="$(CFLAGS)" PROG_SENDMAIL="$(PROG_SENDMAIL)" ../configure ${$*_CONFIG}
	cd $*-build && \
	cp ../Zend/zend_ini_scanner.c ../Zend/zend_language_scanner.c \
	   ../Zend/zend_ini_parser.h ../Zend/zend_language_parser.h \
	   ../Zend/zend_ini_parser.c ../Zend/zend_language_parser.c \
	   Zend/
	touch configure-$*-stamp

build: $(BUILD_TARGETS)
build-%-stamp: configure-%-stamp
	cd $*-build && make $(NUMJOBS)
	touch build-$*-stamp

install: $(INSTALL_TARGETS)
install-%-stamp: build-%-stamp
	if [ -d 5.3-fpm-build ]; then \
		cd 5.3-fpm-build && $(MAKE) $(NUMJOBS) install-fpm; \
		mv $(PREFIX)/php5.3/etc/php-fpm.conf.default $(PREFIX)/php5.3/etc/php-fpm.conf; \
		mv $(PREFIX)/php5.3/sbin/php-fpm $(PREFIX)/php5.3/sbin/psw5.3-fpm; \
	else \
		cd $*-build && $(MAKE) $(NUMJOBS) install; \
		cd ..; \
		mkdir -p $(PREFIX)/php$*/etc/php/conf.d; \
		if [ -f php.ini-recommended ]; then \
			cp php.ini-recommended $(PREFIX)/php$*/etc/php/php.ini; \
		else \
			cp php.ini-production $(PREFIX)/php$*/etc/php/php.ini; \
		fi; \
		cp modules.ini $(PREFIX)/php$*/etc/php/conf.d/modules.ini; \
		if [ -f $(PREFIX)/php$*/etc/php-fpm.conf.default ]; then \
			mv $(PREFIX)/php$*/etc/php-fpm.conf.default $(PREFIX)/php$*/etc/php-fpm.conf; \
		fi; \
		if [ -f $(PREFIX)/php$*/sbin/php-fpm ]; then \
			mv $(PREFIX)/php$*/sbin/php-fpm $(PREFIX)/php$*/sbin/psw$*-fpm; \
		fi; \
	fi
	touch install-$*-stamp

.NOTPARALLEL:
.PHONY: patch unpatch prepared unprepared build clean install configure
