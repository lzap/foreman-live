#version=DEVEL
# Firewall configuration
firewall --enabled --port=80:tcp,443:tcp,53:tcp,53:udp,67:udp,69:udp,8140:tcp

# X Window System configuration information
xconfig  --startxonboot

## Local Mirror 192.168.122.1
#repo --name="CentOS65" --baseurl=http://192.168.122.1/cent65/x86_64
#repo --name="updates" --baseurl=http://192.168.122.1/cent65/updates
#repo --name="SCL" --baseurl=http://192.168.122.1/cent65/SCL/

repo --name=centos-base --baseurl=http://mirror.centos.org/centos/$releasever/os/$basearch/
repo --name=centos-updates --baseurl=http://mirror.centos.org/centos/$releasever/updates/$basearch/
repo --name=centos-scl --baseurl=http://mirror.centos.org/centos/$releasever/SCL/$basearch/

repo --name="epel" --mirrorlist=http://mirrors.fedoraproject.org/metalink?repo=epel-6&arch=$basearch
repo --name="puppetlabs-products" --baseurl=http://yum.puppetlabs.com/el/6/products/x86_64/
repo --name="puppetlabs-deps" --baseurl=http://yum.puppetlabs.com/el/6/dependencies/x86_64/
repo --name="foreman" --baseurl=http://yum.theforeman.org/nightly/el6/x86_64/
repo --name="foreman-plugins" --baseurl=http://yum.theforeman.org/plugins/nightly/el6/x86_64/
repo --name="RDO" --baseurl=http://repos.fedorapeople.org/repos/openstack/openstack-icehouse/epel-6/

# Root password
rootpw root
# System authorization information
auth --useshadow --enablemd5
# System keyboard
keyboard us
# System language
lang en_US.UTF-8
# SELinux configuration
selinux --permissive
# Installation logging level
logging --level=info

# System services
services --disabled="NetworkManager" --enabled="network,httpd,sshd"
network --onboot yes --device eth0 --bootproto static --ip 192.168.223.2 --netmask 255.255.255.0 --gateway 192.168.223.1 --noipv6 --nameserver 192.168.223.2
# System timezone
timezone  US/Eastern
# Disk partitioning information
part / --fstype="ext4" --size=16000

%post

#*******************
# Foreman network configs
#*******************
echo "192.168.223.2 livecd.example.com livecd" >> /etc/hosts

cat > /etc/resolv.conf << EOF
nameserver 192.168.223.2
nameserver 8.8.8.8
EOF

#***********************************************************************
# Create LiveCD configuration file and LiveCD functions
#***********************************************************************

cat > /etc/livesys.conf << 'EOF_livesysconf'
#--------------------------------------------------------------------
# Configuration file for LiveCD
#--------------------------------------------------------------------

# default LiveCD user
LIVECD_DEF_USER="liveuser"

# delay in seconds before auto login
LOGIN_DELAY=15

# Services which are off (not running) on the LiveCD
SERVICES_OFF="mdmonitor setroubleshoot auditd crond atd readahead_early \
              readahead_later kdump microcode_ctl openct pcscd postfix  \
	      yum-updatesd"

# Services which should be on, but are not on per default
SERVICES_ON=""

EOF_livesysconf


cat > /etc/init.d/livesys.functions << 'EOF_livesysfunctions'
#--------------------------------------------------------------------
# livesys functions
#--------------------------------------------------------------------

# egrep_o is a replacement for "egrep -o". It prints only the last matching text
egrep_o() {
   cat | egrep "$1" | sed -r "s/.*($1).*/\\1/"
}

# boot parameter
cmdline_parameter() {
   CMDLINE=/proc/cmdline
   cat "$CMDLINE" | egrep_o "(^|[[:space:]]+)$1(\$|=|[[:space:]]+)" | egrep_o "$1"
}

# boot parameter value
cmdline_value()
{
   CMDLINE=/proc/cmdline
   cat "$CMDLINE" | egrep_o "(^|[[:space:]]+)$1=([^[:space:]]+)" | egrep_o "=.*" | cut -b 2- | tail -n 1
}

exists() {
    which $1 >/dev/null 2>&1 || return
    $*
}

EOF_livesysfunctions


#***********************************************************************
# Create /root/post-install
# Must change "$" to "\$" and "`" to "\`" to avoid shell quoting
#***********************************************************************

cat > /root/post-install << EOF_post
#!/bin/bash

#***********************************************************************
# Create the livesys init script - /etc/rc.d/init.d/livesys
#***********************************************************************

echo "Creating the livesys init script - livesys"

cat > /etc/rc.d/init.d/livesys << EOF_initscript
#!/bin/bash
#
# live: Init script for live image
#
# chkconfig: 345 00 99
# description: Init script for live image.

. /etc/init.d/functions
. /etc/livesys.conf
. /etc/init.d/livesys.functions

# exit if not running from LiveCD
if [ ! "\\\$( cmdline_parameter liveimg )" ] || [ "\\\$1" != "start" ]; then
    exit 0
fi

[ -e /.liveimg-configured ] && configdone=1

touch /.liveimg-configured

### read boot parameters out of /proc/cmdline

# hostname
hostname=\\\$( cmdline_value hostname )

# afs cell
CELL=\\\$( cmdline_value cell )

# services to turn on / off
SERVICEON=\\\$( cmdline_value serviceon )
SERVICEOFF=\\\$( cmdline_value serviceoff )

# cups server
CUPS=\\\$( cmdline_value cups )

# password
PW=\\\$( cmdline_value pw )
[ ! \\\$PW ] && PW=\\\$( cmdline_value passwd )

# set livecd user
LIVECD_USER=\\\$( cmdline_value user )
[ ! "\\\$LIVECD_USER" ] && LIVECD_USER=\\\$LIVECD_DEF_USER


### mount live image
if [ -b \\\`readlink -f /dev/live\\\` ]; then
   mkdir -p /mnt/live
   mount -o ro /dev/live /mnt/live 2>/dev/null || mount /dev/live /mnt/live
fi

livedir=\\\$( cmdline_value live_dir )
[ ! "\\\$livedir" ] && livedir="LiveOS"

### enable swaps unless requested otherwise
swaps=\\\`blkid -t TYPE=swap -o device\\\`
if [ ! "\\\$( cmdline_parameter noswap )" ] && [ -n "\\\$swaps" ] ; then
  for s in \\\$swaps ; do
    action "Enabling swap partition \\\$s" swapon \\\$s
  done
fi
if [ ! "\\\$( cmdline_parameter noswap )" ] && [ -f /mnt/live/\\\${livedir}/swap.img ] ; then
  action "Enabling swap file" swapon /mnt/live/\\\${livedir}/swap.img
fi

### functions for persisten Home 
mountPersistentHome() {
  # support label/uuid
  if [ "\\\${homedev##LABEL=}" != "\\\${homedev}" -o "\\\${homedev##UUID=}" != "\\\${homedev}" ]; then
    homedev=\\\`/sbin/blkid -o device -t "\\\$homedev"\\\`
  fi

  # if we're given a file rather than a blockdev, loopback it
  if [ "\\\${homedev##mtd}" != "\\\${homedev}" ]; then
    # mtd devs don't have a block device but get magic-mounted with -t jffs2
    mountopts="-t jffs2"
  elif [ ! -b "\\\$homedev" ]; then
    loopdev=\\\`losetup -f\\\`
    if [ "\\\${homedev##/mnt/live}" != "\\\${homedev}" ]; then
      action "Remounting live store r/w" mount -o remount,rw /mnt/live
    fi
    losetup \\\$loopdev \\\$homedev
    homedev=\\\$loopdev
  fi

  # if it's encrypted, we need to unlock it
  if [ "\\\$(/sbin/blkid -s TYPE -o value \\\$homedev 2>/dev/null)" = "crypto_LUKS" ]; then
    echo
    echo "Setting up encrypted /home device"
    plymouth ask-for-password --command="cryptsetup luksOpen \\\$homedev EncHome"
    homedev=/dev/mapper/EncHome
  fi

  # and finally do the mount
  mount \\\$mountopts \\\$homedev /home
  # if we have /home under what's passed for persistent home, then
  # we should make that the real /home.  useful for mtd device on olpc
  if [ -d /home/home ]; then mount --bind /home/home /home ; fi
  [ -x /sbin/restorecon ] && /sbin/restorecon /home
  if [ -d /home/\\\$LIVECD_USER ]; then USERADDARGS="-M" ; fi
}

findPersistentHome() {
  for arg in \\\`cat /proc/cmdline\\\` ; do
    if [ "\\\${arg##persistenthome=}" != "\\\${arg}" ]; then
      homedev=\\\${arg##persistenthome=}
      return
    fi
  done
}

if strstr "\\\`cat /proc/cmdline\\\`" persistenthome= ; then
  findPersistentHome
elif [ -e /mnt/live/\\\${livedir}/home.img ]; then
  homedev=/mnt/live/\\\${livedir}/home.img
fi

### if we have a persistent /home, then we want to go ahead and mount it
if ! strstr "\\\`cat /proc/cmdline\\\`" nopersistenthome && [ -n "\\\$homedev" ] ; then
  action "Mounting persistent /home" mountPersistentHome
fi

### make it so that we don't do writing to the overlay for things which
### are just tmpdirs/caches
mount -t tmpfs -o mode=0755 varcacheyum /var/cache/yum
mount -t tmpfs tmp /tmp
mount -t tmpfs vartmp /var/tmp
[ -x /sbin/restorecon ] && /sbin/restorecon /var/cache/yum /tmp /var/tmp >/dev/null 2>&1
mount -t tmpfs varlibglance /var/lib/glance
mount -t tmpfs varlibmysql /var/lib/mysql
mount -t tmpfs varliblibvirt /var/lib/libvirt
mount -t tmpfs varrun /var/run
mount -t tmpfs varlock /var/lock
mount -t tmpfs varlog /var/log

# create subdirs for convenience
mkdir /var/lock/subsys
mkdir /var/run/dbus
mkdir /var/run/NetworkManager
mkdir /var/run/mysqld && chown mysql:mysql /var/run/mysqld
mkdir /var/run/httpd && chown apache:apache /var/run/httpd
mkdir /var/log/httpd && chown apache:apache /var/log/httpd

[ -x /sbin/restorecon ] && /sbin/restorecon /var/lib/mysql /var/lib/libvirt /var/run /var/lock /var/log > /dev/null 2>&1

### set afs cell if given by boot parameter
if [ "\\\$CELL" ]; then
    [ -e /usr/vice/etc/ThisCell ] && echo \\\$CELL > /usr/vice/etc/ThisCell
fi

### set cups server
if [ "\\\$CUPS" ]; then
    if [ -e /etc/cups/client.conf ]; then
        sed -i "s|.*ServerName .*|ServerName  \\\$CUPS|" /etc/cups/client.conf
        grep -q ServerName /etc/cups/client.conf || echo "ServerName  \\\$CUPS" >> /etc/cups/client.conf 
    fi
fi

### set horizon address to allow 127.0.0.1
sed -i -e "/ALLOWED_HOSTS/ s/\]/, '127.0.0.1']" /etc/openstack_dashboard/local_settings

### set the LiveCD hostname
[ ! "\\\$hostname" ] && hostname="livecd.example.com"
sed -i -e "s|HOSTNAME=.*|HOSTNAME=\\\$hostname|g" /etc/sysconfig/network
/bin/hostname \\\$hostname

#-----------------------------------------------------------------------
# EXIT here if LiveCD has already been configured         
# happens if you start the LiveCD with persistent changes 
#-----------------------------------------------------------------------

[ "\\\$configdone" ] && exit 0

### turn off services, which are not useful on LiveCD, to preserve resources
if [ "\\\$SERVICES_OFF" ]; then
    for service in \\\$SERVICES_OFF ; do
        [ -f /etc/init.d/\\\$service ] && chkconfig \\\$service off 2>/dev/null
    done
fi

### turn on services, which are off by default
if [ "\\\$SERVICES_ON" ]; then
    for service in \\\$SERVICES_ON ; do
        [ -f /etc/init.d/\\\$service ] && chkconfig \\\$service ofn  2>/dev/null
    done
fi

### services off, from command line parameter (turn it off once again)
if [ "\\\$SERVICEOFF" ]; then
    for service in \\\$( echo "\\\$SERVICEOFF" | tr ':' ' ' ); do
        [ -f /etc/init.d/\\\$service ] && chkconfig \\\$service off 2>/dev/null
    done
fi

# services on, from command line parameter (turn it ofn once again)
if [ "\\\$SERVICEON" ]; then
    for service in \\\$( echo "\\\$SERVICEON" | tr ':' ' ' ); do
        [ -f /etc/init.d/\\\$service ] && chkconfig \\\$service on  2>/dev/null
    done
fi

### fix various bugs and issues
# unmute sound card
exists alsaunmute 0 2> /dev/null

# turn off firstboot for livecd boots
echo "RUN_FIRSTBOOT=NO" > /etc/sysconfig/firstboot

# start afs with option -memcache (gets a kernel panic on some system - do not use it for the moment)
# [ -e /etc/sysconfig/afs ] && sed -i "s|^OPTIONS=.*|OPTIONS=\"-memcache\"|" /etc/sysconfig/afs

# Stopgap fix for RH #217966; should be fixed in HAL instead
touch /media/.hal-mtab

### create the LiveCD default user
# add default user with no password
/usr/sbin/useradd -c "LiveCD default user" \\\$LIVECD_USER
/usr/bin/passwd -d \\\$LIVECD_USER > /dev/null
# give default user sudo privileges
 echo "\\\$LIVECD_USER     ALL=(ALL)     NOPASSWD: ALL" >> /etc/sudoers

### set password
if [ "\\\$PW" ]; then
    echo \\\$PW | passwd --stdin root >/dev/null
    echo \\\$PW | passwd --stdin \\\$LIVECD_USER >/dev/null
fi

### enable auto-login
if [ ! "\\\$( cmdline_parameter noautologin )" ]; then
    cat >> /etc/gdm/custom.conf << FOE
[daemon]
TimedLoginEnable=true
TimedLogin=LIVECD_USER
TimedLoginDelay=\\\$LOGIN_DELAY
FOE
    sed -i "s|LIVECD_USER|\\\$LIVECD_USER|" /etc/gdm/custom.conf
fi

### add keyboard and display configuration utilities to the desktop
mkdir -p /home/\\\$LIVECD_USER/Desktop >/dev/null
cp /usr/share/applications/gnome-keyboard.desktop           /home/\\\$LIVECD_USER/Desktop/
cp /usr/share/applications/gnome-display-properties.desktop /home/\\\$LIVECD_USER/Desktop/

### disable screensaver locking
gconftool-2 --direct --config-source=xml:readwrite:/etc/gconf/gconf.xml.defaults -s -t bool   /apps/gnome-screensaver/lock_enabled "false" >/dev/null

### don't do packagekit checking by default
gconftool-2 --direct --config-source=xml:readwrite:/etc/gconf/gconf.xml.defaults -s -t int /apps/gnome-packagekit/update-icon/frequency_get_updates "0" >/dev/null
gconftool-2 --direct --config-source=xml:readwrite:/etc/gconf/gconf.xml.defaults -s -t string /apps/gnome-packagekit/update-icon/frequency_get_updates never >/dev/null
gconftool-2 --direct --config-source=xml:readwrite:/etc/gconf/gconf.xml.defaults -s -t string /apps/gnome-packagekit/update-icon/frequency_get_upgrades never >/dev/null
gconftool-2 --direct --config-source=xml:readwrite:/etc/gconf/gconf.xml.defaults -s -t string /apps/gnome-packagekit/update-icon/frequency_refresh_cache never >/dev/null
gconftool-2 --direct --config-source=xml:readwrite:/etc/gconf/gconf.xml.defaults -s -t bool /apps/gnome-packagekit/update-icon/notify_available false >/dev/null
gconftool-2 --direct --config-source=xml:readwrite:/etc/gconf/gconf.xml.defaults -s -t bool /apps/gnome-packagekit/update-icon/notify_distro_upgrades false >/dev/null
gconftool-2 --direct --config-source=xml:readwrite:/etc/gconf/gconf.xml.defaults -s -t bool /apps/gnome-packagekit/enable_check_firmware false >/dev/null
gconftool-2 --direct --config-source=xml:readwrite:/etc/gconf/gconf.xml.defaults -s -t bool /apps/gnome-packagekit/enable_check_hardware false >/dev/null
gconftool-2 --direct --config-source=xml:readwrite:/etc/gconf/gconf.xml.defaults -s -t bool /apps/gnome-packagekit/enable_codec_helper false >/dev/null
gconftool-2 --direct --config-source=xml:readwrite:/etc/gconf/gconf.xml.defaults -s -t bool /apps/gnome-packagekit/enable_font_helper false >/dev/null
gconftool-2 --direct --config-source=xml:readwrite:/etc/gconf/gconf.xml.defaults -s -t bool /apps/gnome-packagekit/enable_mime_type_helper false >/dev/null

### start system-config-firewall with su 
#  (bugfix: system-config-firewall does not work when root has no password)
sed -i "s|^Exec=.*|Exec=su - -c /usr/bin/system-config-firewall|" /usr/share/applications/system-config-firewall.desktop
sed -i "s|^Terminal=.*|Terminal=true|"                            /usr/share/applications/system-config-firewall.desktop

### don't use prelink on a running live image
sed -i 's/PRELINKING=yes/PRELINKING=no/' /etc/sysconfig/prelink &>/dev/null


###-----------------------------------------------------------------------
# detecting disk partitions and logical volumes (disabled by default)
# use boot parameter automount to enable it
###-----------------------------------------------------------------------

CreateDesktopIconHD()
{
cat > /home/\\\$LIVECD_USER/Desktop/Local\ hard\ drives.desktop << EOF_HDicon
[Desktop Entry]
Encoding=UTF-8
Version=1.0
Type=Link
Name=Local hard drives
Name[en_US]=Local hard drives
Name[fr_CA]=Disques durs locaux
URL=/mnt/disc
Icon=/usr/share/icons/gnome/32x32/devices/gnome-dev-harddisk.png
EOF_HDicon

chmod 755 /home/\\\$LIVECD_USER/Desktop/Local\ hard\ drives.desktop
}

CreateDesktopIconLVM()
{
mkdir -p /home/\\\$LIVECD_USER/Desktop >/dev/null

cat > /home/\\\$LIVECD_USER/Desktop/Local\ logical\ volumes.desktop << EOF_LVMicon
[Desktop Entry]
Encoding=UTF-8
Version=1.0
Type=Link
Name=Local logical volumes
Name[en_US]=Local logical volumes
Name[fr_CA]=Volumes logiques locaux
URL=/mnt/lvm
Icon=/usr/share/icons/gnome/32x32/devices/gnome-dev-harddisk.png
EOF_LVMicon

chmod 755 /home/\\\$LIVECD_USER/Desktop/Local\ logical\ volumes.desktop
}

# mount disk partitions if 'automount' is given as a boot option
if [ "\\\$( cmdline_parameter automount )" ]; then
	MOUNTOPTION="rw"
	HARD_DISKS=\\\`egrep "[sh]d.\\\$" /proc/partitions | tr -s ' ' | sed 's/^  *//' | cut -d' ' -f4\\\`

	echo "Mounting hard disk partitions... "
	for DISK in \\\$HARD_DISKS; do
	    # Get the device and system info from fdisk (but only for fat and linux partitions).
	    FDISK_INFO=\\\`fdisk -l /dev/\\\$DISK | tr [A-Z] [a-z] | egrep "fat|linux" | egrep -v "swap|extended|lvm" | sed 's/*//' | tr -s ' ' | tr ' ' ':' | cut -d':' -f1,6-\\\`
	    for FDISK_ENTRY in \\\$FDISK_INFO; do
		PARTITION=\\\`echo \\\$FDISK_ENTRY | cut -d':' -f1\\\`
		MOUNTPOINT="/mnt/disc/\\\${PARTITION##/dev/}"
		mkdir -p \\\$MOUNTPOINT
		MOUNTED=FALSE

		# get the partition type
		case \\\`echo \\\$FDISK_ENTRY | cut -d':' -f2-\\\` in
		*fat*) 
		    FSTYPES="vfat"
		    EXTRAOPTIONS=",uid=500";;
		*)
		    FSTYPES="ext4 ext3 ext2"
		    EXTRAOPTIONS="";;
		esac

		# try to mount the partition
		for FSTYPE in \\\$FSTYPES; do
		    if mount -o "\\\${MOUNTOPTION}\\\${EXTRAOPTIONS}" -t \\\$FSTYPE \\\$PARTITION \\\$MOUNTPOINT &>/dev/null; then
			echo "\\\$PARTITION \\\$MOUNTPOINT \\\$FSTYPE noauto,\\\${MOUNTOPTION}\\\${EXTRAOPTIONS} 0 0" >> /etc/fstab
			echo -n "\\\$PARTITION "
			MOUNTED=TRUE
			CreateDesktopIconHD
		    fi
		done
		[ \\\$MOUNTED = "FALSE" ] && rmdir \\\$MOUNTPOINT
	    done
	done
	echo
fi

# mount logical volumes if 'automount' is given as a boot option
if [ "\\\$( cmdline_parameter automount )" ]; then
        MOUNTOPTION="rw"
	FSTYPES="ext4 ext3 ext2"
	echo "Scanning for logical volumes..."
	if ! lvm vgscan 2>&1 | grep "No volume groups"; then
	    echo "Activating logical volumes ..."
	    modprobe dm_mod >/dev/null
	    lvm vgchange -ay
	    LOGICAL_VOLUMES=\\\`lvm lvdisplay -c | sed "s/^  *//" | cut -d: -f1\\\`
	    if [ ! -z "\\\$LOGICAL_VOLUMES" ]; then
		echo "Making device nodes ..."
		lvm vgmknodes
		echo -n "Mounting logical volumes ... "
		for VOLUME_NAME in \\\$LOGICAL_VOLUMES; do
		    VG_NAME=\\\`echo \\\$VOLUME_NAME | cut -d/ -f3\\\`
		    LV_NAME=\\\`echo \\\$VOLUME_NAME | cut -d/ -f4\\\`
		    MOUNTPOINT="/mnt/lvm/\\\${VG_NAME}-\\\${LV_NAME}"
		    mkdir -p \\\$MOUNTPOINT

		    MOUNTED=FALSE
		    for FSTYPE in \\\$FSTYPES; do
			if mount -o \\\$MOUNTOPTION -t \\\$FSTYPE \\\$VOLUME_NAME \\\$MOUNTPOINT &>/dev/null; then
			    echo "\\\$VOLUME_NAME \\\$MOUNTPOINT \\\$FSTYPE defaults,\\\${MOUNTOPTION} 0 0" >> /etc/fstab
			    echo -n "\\\$VOLUME_NAME "
			    MOUNTED=TRUE
			    CreateDesktopIconLVM
			    break
			fi
		    done
		    [ \\\$MOUNTED = FALSE ] && rmdir \\\$MOUNTPOINT
		done
		echo

	    else
		echo "No logical volumes found"
	    fi
	fi
fi

### give back ownership to the default user
chown -R \\\$LIVECD_USER:\\\$LIVECD_USER /home/\\\$LIVECD_USER

EOF_initscript
#***********************************************************************
# End of livesys script
#***********************************************************************


#***********************************************************************
# Create the livesys init script - /etc/rc.d/init.d/livesys-late
#***********************************************************************

echo "Creating the livesys init script - livesys-late"

cat > /etc/rc.d/init.d/livesys-late << EOF_lateinitscript
#!/bin/bash
#
# live: Late init script for live image
#
# chkconfig: 345 99 01
# description: Late init script for live image.

. /etc/init.d/functions
. /etc/livesys.conf
. /etc/init.d/livesys.functions

# exit if not running from LiveCD
if [ ! "\\\$( cmdline_parameter liveimg )" ] || [ "\\\$1" != "start" ]; then
    exit 0
fi

touch /.liveimg-late-configured

# read boot parameters out of /proc/cmdline
ks=\\\$( cmdline_value ks )
xdriver=\\\$( cmdline_value xdriver )
kb=\\\$( cmdline_value kb )

# if liveinst or textinst is given, start anaconda
if [ "\\\$( cmdline_parameter liveinst )" ]; then
   plymouth --quit
   /usr/sbin/liveinst \\\$ks
   /sbin/reboot
fi
if [ "\\\$( cmdline_parameter textinst )" ] ; then
   plymouth --quit
   /usr/sbin/liveinst --text \\\$ks
   /sbin/reboot
fi

# configure X, allowing user to override xdriver 
# (does not work in SL6 with xorg 7.4)
# if [ -n "\\\$xdriver" ]; then
#   cat > /etc/X11/xorg.conf.d/00-xdriver.conf <<FOE
# Section "Device"
#        Identifier      "Videocard0"
#        Driver          "\\\$xdriver"
# EndSection
# FOE
# fi

# configure X, allowing user to override xdriver
# (does not work in SL6 because system-config-display is missing)
if [ -n "\\\$xdriver" ]; then
   exists system-config-display --noui --reconfig --set-depth=24 \\\$xdriver
fi

# configure keyboard
# (does not work in SL6 because system-config-keyboard is missing)
if [ "\\\$kb" ]; then
    exists system-config-keyboard --noui \\\$kb 
fi


EOF_lateinitscript
#***********************************************************************
# End of livesys-late script
#***********************************************************************


#***********************************************************************
# Create /sbin/halt.local
#***********************************************************************

echo "Creating /sbin/halt.local"

cat > /sbin/halt.local << EOF_haltlocal
#!/bin/bash
#
# Ejects LiveCD/DVD, if boot parameter eject is given 
#

. /etc/init.d/functions
. /etc/livesys.conf
. /etc/init.d/livesys.functions

# exit if not running from LiveCD
if [ ! "\\\$( cmdline_parameter liveimg )" ]; then
    exit 0
fi
if [ "\\\$( cmdline_parameter eject )" ]; then
    echo "Eject CD/DVD ..."
    /usr/sbin/eject -p -m \\\$(readlink -f /dev/live) >/dev/null 2>&1
fi

EOF_haltlocal
#***********************************************************************
# End of /sbin/halt.local script
#***********************************************************************
chmod 755 /sbin/halt.local


#***********************************************************************
# Configure the LiveCD
# Everything configured here will survive LiveCD install to harddisk !
#***********************************************************************

echo "Configure the LiveCD"

chmod 755 /etc/rc.d/init.d/livesys
/sbin/restorecon /etc/rc.d/init.d/livesys
/sbin/chkconfig --add livesys

chmod 755 /etc/rc.d/init.d/livesys-late
/sbin/restorecon /etc/rc.d/init.d/livesys-late
/sbin/chkconfig --add livesys-late

# go ahead and pre-make the man -k cache (#455968)
/usr/sbin/makewhatis -w

# save a little bit of space at least...
rm -f /var/lib/rpm/__db*
rm -f /boot/initrd*
rm -f /boot/initramfs*
# make sure there aren't core files lying around
rm -f /core*

# convince readahead not to collect
rm -f /.readahead_collect
touch /var/lib/readahead/early.sorted

# workaround clock syncing on shutdown that we don't want (#297421)
sed -i -e 's/hwclock/no-such-hwclock/g' /etc/rc.d/init.d/halt

# import RPM GPG keys
for i in /etc/pki/rpm-gpg/*; do
    rpm --import $i
done

# evolution is in the gnome launch panel (bad workaround to start thunderbird instead)
[ ! -e /usr/bin/evolution ] && ln -s /usr/bin/thunderbird /usr/bin/evolution

# clean up yum
yum clean all

# workaround avahi segfault (#279301)
touch /etc/resolv.conf
/sbin/restorecon /etc/resolv.conf

# create locate db
/etc/cron.daily/mlocate.cron

# list kernel just for debugging
rpm -q kernel

EOF_post

# run post-install script
/bin/bash -x /root/post-install 2>&1 | tee /root/post-install.log


%end

%post --nochroot

#***********************************************************************
# Create /root/postnochroot-install
# Must change "$" to "\$" and "`" to "\`" to avoid shell quoting
#***********************************************************************

cat > postnochroot-install << EOF_postnochroot
#!/bin/bash

# Copy licensing information
cp $INSTALL_ROOT/usr/share/doc/*-release-*/GPL $LIVE_ROOT/GPL

# customize boot menu entries
grep -B4 'menu default'            \$LIVE_ROOT/isolinux/isolinux.cfg > \$LIVE_ROOT/isolinux/default.txt
grep -B3 'xdriver=vesa nomodeset'  \$LIVE_ROOT/isolinux/isolinux.cfg > \$LIVE_ROOT/isolinux/basicvideo.txt
grep -A3 'label check0'            \$LIVE_ROOT/isolinux/isolinux.cfg > \$LIVE_ROOT/isolinux/check.txt
grep -A2 'label memtest'           \$LIVE_ROOT/isolinux/isolinux.cfg > \$LIVE_ROOT/isolinux/memtest.txt
grep -A2 'label local'             \$LIVE_ROOT/isolinux/isolinux.cfg > \$LIVE_ROOT/isolinux/localboot.txt

sed "s/label linux0/label linuxtext0/"   \$LIVE_ROOT/isolinux/default.txt > \$LIVE_ROOT/isolinux/textboot.txt
sed -i "s/Boot/Boot (Text Mode)/"                                           \$LIVE_ROOT/isolinux/textboot.txt
sed -i "s/liveimg/liveimg 3/"                                               \$LIVE_ROOT/isolinux/textboot.txt
sed -i "/menu default/d"                                                    \$LIVE_ROOT/isolinux/textboot.txt

sed "s/label linux0/label install0/"     \$LIVE_ROOT/isolinux/default.txt > \$LIVE_ROOT/isolinux/install.txt
sed -i "s/Boot/Install/"                                                    \$LIVE_ROOT/isolinux/install.txt
sed -i "s/liveimg/liveimg liveinst noswap/"                                 \$LIVE_ROOT/isolinux/install.txt
sed -i "s/ quiet / /"                                                       \$LIVE_ROOT/isolinux/install.txt
sed -i "s/ rhgb / /"                                                        \$LIVE_ROOT/isolinux/install.txt
sed -i "/menu default/d"                                                    \$LIVE_ROOT/isolinux/install.txt

sed "s/label linux0/label textinstall0/" \$LIVE_ROOT/isolinux/default.txt > \$LIVE_ROOT/isolinux/textinstall.txt
sed -i "s/Boot/Install (Text Mode)/"                                        \$LIVE_ROOT/isolinux/textinstall.txt
sed -i "s/liveimg/liveimg textinst noswap/"                                 \$LIVE_ROOT/isolinux/textinstall.txt
sed -i "s/ quiet / /"                                                       \$LIVE_ROOT/isolinux/textinstall.txt
sed -i "s/ rhgb / /"                                                        \$LIVE_ROOT/isolinux/textinstall.txt
sed -i "/menu default/d"                                                    \$LIVE_ROOT/isolinux/textinstall.txt

cat \$LIVE_ROOT/isolinux/default.txt \$LIVE_ROOT/isolinux/basicvideo.txt \$LIVE_ROOT/isolinux/check.txt \$LIVE_ROOT/isolinux/memtest.txt \$LIVE_ROOT/isolinux/localboot.txt > \$LIVE_ROOT/isolinux/current.txt

diff \$LIVE_ROOT/isolinux/isolinux.cfg \$LIVE_ROOT/isolinux/current.txt | sed '/^[0-9][0-9]*/d; s/^. //; /^---$/d' > \$LIVE_ROOT/isolinux/cleaned.txt

cat \$LIVE_ROOT/isolinux/cleaned.txt      \
    \$LIVE_ROOT/isolinux/default.txt      \
    \$LIVE_ROOT/isolinux/textboot.txt     \
    \$LIVE_ROOT/isolinux/basicvideo.txt   \
    \$LIVE_ROOT/isolinux/check.txt        \
    \$LIVE_ROOT/isolinux/install.txt      \
    \$LIVE_ROOT/isolinux/textinstall.txt  \
    \$LIVE_ROOT/isolinux/memtest.txt      \
    \$LIVE_ROOT/isolinux/localboot.txt > \$LIVE_ROOT/isolinux/isolinux.cfg
rm -f \$LIVE_ROOT/isolinux/*.txt

EOF_postnochroot

# run postnochroot-install script
/bin/bash -x postnochroot-install 2>&1 | tee postnochroot-install.log
cp postnochroot-install postnochroot-install.log ${INSTALL_ROOT}/root



%end

%post --nochroot
cp foreman_setup.sh $INSTALL_ROOT/usr/local/src/
%end

%post

# remove folders/files that use a lot of diskspace
# and are not really needed for LiveCD
rm -rf /usr/share/doc/openafs-*
rm -rf /usr/share/doc/testdisk-*

#workaround for bz 878119
#echo 'blacklist iTCO_wdt' >> /etc/modprobe.d/blacklist.conf
#echo 'blacklist iTCO_vendor_support' >> /etc/modprobe.d/blacklist.conf
sed -i 's/\#WDMDOPTS/WDMDOPTS/g' /etc/sysconfig/wdmd

#configuring autostart
mkdir -p /home/liveuser/.config/autostart

# create desktop shortcut
cat > /usr/share/applications/foreman_setup.desktop << EOF
[Desktop Entry]
Type=Application
Encoding=UTF-8
Version=1.0
Name=Foreman Setup
Name[en_US]=Foreman Setup
Exec=/usr/bin/gnome-terminal -e "bash -c /home/liveuser/foreman_setup.sh;bash"
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=5
#Icon=/home/openstackuser/openstackLiveFiles/images/OPENSTACK-128x128.jpg
EOF
chmod +x /usr/share/applications/foreman_setup.desktop

#link setup in autostart
cp /usr/share/applications/foreman_setup.desktop /home/liveuser/.config/autostart/

# create foreman_setup.sh
cp /usr/local/src/foreman_setup.sh /home/liveuser

#generating rsa keys
ssh-keygen -N "" -f /root/.ssh/id_rsa
cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys

%end

%packages
@base
@basic-desktop
@core
@desktop-platform
@fonts
@general-desktop
@graphical-admin-tools
@internet-applications
@internet-browser
@network-file-system-client
@network-tools
@x11


#foreman packages
foreman
ruby193-rubygem-foreman_discovery
ruby193-rubygem-staypuft
openstack-puppet-modules
foreman-installer
foreman-installer-staypuft

#foreman dependencies
bind
bind-utils
dhcp
foreman-postgresql
foreman-proxy
foreman-selinux
httpd
mod_passenger
mod_ssl
mysql-server
postgresql-server
puppet-server
ruby193-rubygem-passenger-native
rubygem-foreman_api
rubygem-passenger-native
tftp-server
wget
xinetd
#end forman packages

vim-enhanced

anaconda
bridge-utils
busybox
compat-readline5
cups
cups-pk-helper
device-mapper-multipath
dracut-network
epel-release
facter
firefox
fuse
isomd5sum
kernel
libselinux-ruby
livecd-tools
lvm2
m2crypto
mailx
memtest86+
mysql
mysql-server
nautilus-sendto
net-tools
numpy
patch
perl-DBD-MySQL
perl-DBI
phonon-backend-gstreamer
puppet
python-django-openstack-auth
qemu-kvm-tools
qpid-cpp-client
qpid-cpp-server
rdesktop
ruby
ruby-augeas
ruby-libs
ruby-shadow
sanlock
seabios
shadow-utils
spice-client
spice-xpi
squashfs-tools
syslinux
system-config-firewall-base
system-config-printer
system-config-printer-udev
tsclient
tuned
vim
wpa_supplicant
xorg-x11-fonts-100dpi
xorg-x11-fonts-ISO8859-1-100dpi
xorg-x11-fonts-Type1
yum-plugin-fastestmirror
yum-plugin-priorities
-autofs
-cjkuni-fonts-common
-cjkuni-uming-fonts
-compiz
-compiz-gnome
-ed
-ekiga
-evince-dvi
-evolution
-evolution-help
-evolution-mapi
-gnome-backgrounds
-gnome-user-share
-gnote
-gok
-hunspell-*
-ibus-hangul
-kexec-tools
-lftp
-libaio
-libhangul
-libhugetlbfs
-microcode_ctl
-mousetweaks
-nano
-openswan
-orca
-pidgin
-pinentry-gtk
-pinfo
-psacct
-qt3
-quota
-redhat-lsb
-redhat-lsb-graphics
-rhythmbox
-samba-client
-samba-common
-scenery-backgrounds
-seahorse
-smartmontools
-sound-juicer
-system-config-kdump
-thunderbird
-vim-common
-vino
-words
-xinetd

%end
