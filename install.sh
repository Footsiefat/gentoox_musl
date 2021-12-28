#!/bin/bash
if [ $(id -u) != "0" ]; then
	echo "This script must be run as root" 1>&2
	exit 1
fi

set -e
echo -e 'Welcome to the GentooX setup, the installation mainly consists of:
\t- providing this script with a target partition where system will be installed
\t- extracting precompiled squashfs system image into the specified partition
\t- setting up GRUB. BIOS or UEFI mode will be used depending how system was booted
\tGentooX uses openSUSE-style BTRFS root partition & subvolumes for snapshotting with snapper
\tGentooX requires minimum of 16GB of space, and use of BTRFS is hardcoded

Manual installation can be done via:
  mounting target partition to /mnt/install
  unsquashfs -f -i -d /mnt/install/ /mnt/cdrom/image.squashfs
  /usr/local/sbin/genfstab -U >> /mnt/install/etc/fstab
  /usr/local/sbin/arch-chroot /mnt/install/
  grub-install --target=x86_64-efi for UEFI mode, or grub-install --target=i386-pc (BIOS only)
  grub-mkconfig -o /boot/grub/grub.cfg

\033[1mThis script will perform automatic guided installation. Automatic partitioning is recommended.\n\033[0m'


declare -A PART_SCHEME
PART_SCHEME[a]="Automatic"
PART_SCHEME[m]="Manual"
if [[ -d /sys/firmware/efi/ ]]; then UEFI_MODE=y; fi


setup_btrfs () {
	DEVICE=$1

	mkfs.btrfs -f -L GENTOO $DEVICE
	mkdir -p /mnt/install
	mount -o compress=lzo $DEVICE /mnt/install

	btrfs subvolume create /mnt/install/@
	btrfs subvolume create /mnt/install/@/.snapshots
	mkdir /mnt/install/@/.snapshots/1
	btrfs subvolume create /mnt/install/@/.snapshots/1/snapshot
	mkdir -p /mnt/install/@/boot/grub/
	#btrfs subvolume create /mnt/install/@/boot/grub/i386-pc
	#btrfs subvolume create /mnt/install/@/boot/grub/x86_64-efi
	btrfs subvolume create /mnt/install/@/home
	btrfs subvolume create /mnt/install/@/opt
	btrfs subvolume create /mnt/install/@/root
	btrfs subvolume create /mnt/install/@/srv
	#btrfs subvolume create /mnt/install/@/tmp
	mkdir /mnt/install/@/usr/
	btrfs subvolume create /mnt/install/@/usr/local
	btrfs subvolume create /mnt/install/@/var

	chattr +C /mnt/install/@/var

	echo "<?xml version=\"1.0\"?>
	<snapshot>
	  <type>single</type>
	  <num>1</num>
	  <date>$(date)</date>
	  <description>first root filesystem</description>
	</snapshot>" > /mnt/install/@/.snapshots/1/info.xml

	btrfs subvolume set-default $(btrfs subvolume list /mnt/install | grep "@/.snapshots/1/snapshot" | grep -oP '(?<=ID )[0-9]+') /mnt/install
	umount /mnt/install
	mount -o compress=lzo $DEVICE /mnt/install

	# ls /mnt/install should respond with empty result

	mkdir /mnt/install/.snapshots
	mkdir /mnt/install/boot
	#mkdir -p /mnt/install/boot/grub/i386-pc
	#mkdir -p /mnt/install/boot/grub/x86_64-efi
	mkdir /mnt/install/home
	mkdir /mnt/install/opt
	mkdir /mnt/install/root
	mkdir /mnt/install/srv
	#mkdir /mnt/install/tmp
	mkdir -p /mnt/install/usr/local
	mkdir /mnt/install/var

	mount $DEVICE /mnt/install/.snapshots -o subvol=@/.snapshots
	#mount $DEVICE /mnt/install/boot/grub/i386-pc -o subvol=@/boot/grub/i386-pc
	#mount $DEVICE /mnt/install/boot/grub/x86_64-efi -o subvol=@/boot/grub/x86_64-efi
	mount $DEVICE /mnt/install/home -o subvol=@/home
	mount $DEVICE /mnt/install/opt -o subvol=@/opt
	mount $DEVICE /mnt/install/root -o subvol=@/root
	mount $DEVICE /mnt/install/srv -o subvol=@/srv
	#mount $DEVICE /mnt/install/tmp -o subvol=@/tmp
	mount $DEVICE /mnt/install/usr/local -o subvol=@/usr/local
	mount $DEVICE /mnt/install/var -o subvol=@/var
}


echo -e "\nDetected drives:\n$(lsblk | grep -e NAME -e disk -e part)"
if [[ ! -z $UEFI_MODE ]]; then echo -e "\nEFI boot detected"; fi

while :; do
	echo
	read -erp "Automatic partitioning (a), or manual partitioning ((m), will launch parted)? [a/m] " -n 1 partitioning_mode
	esppart="None"
	if [[ $partitioning_mode = "a" ]]; then
	drive_guess=$(lsblk | grep -q nvme && echo "/dev/nvme0n1" || echo "/dev/sda")
	echo -e "\033[1mAll data on drive selected below will be destroyed. You will be asked for confirmation.\033[0m"

	read -erp "Enter drive to be partitioned for GentooX installation: " -i $drive_guess drive
        if [[ ! -z $UEFI_MODE ]]; then
          if [[ $drive =~ "nvme" ]]; then esppart="${drive}p1"; partition="${drive}p2"; else esppart="${drive}1"; partition="${drive}2"; fi # UEFI mode
        else
          if [[ $drive =~ "nvme" ]]; then partition="${drive}p1"; else partition="${drive}1"; fi # BIOS mode
        fi
	elif [[ $partitioning_mode = "m" ]]; then
	esppart="User will be asked"
        if [[ ! -z $UEFI_MODE ]]; then echo -e "EFI boot detected, create an EF00 ESP EFI partition if one doesn't exist, this script will ask for it...\n"; fi
		parted
		read -erp "Enter formatted root (/) partition for GentooX installation (e.g. /dev/nvme0n1p2): " -i "/dev/sda1" partition
	else
		echo "Invalid option"
		continue
	fi

	read -erp "Partitioning: ${PART_SCHEME[$partitioning_mode]}
    NOTE: in BIOS mode, only 1 partition is used for the whole OS including /boot,
          in UEFI 2 partitions are used, /boot/efi for ESP EFI and 2nd for root (/)
    EFI partition:  $esppart
    Root partition: $partition  (for GentooX)
    Is this correct? [y/n] " -n 1 yn
	if [[ $yn == "y" ]]; then
		break
	fi
done


if [[ $partitioning_mode = "a" ]]; then
  wipefs --all --quiet $drive && sync
  if [[ ! -z $UEFI_MODE ]]; then
	echo -e "o\nY\nn\n\n\n+256M\nEF00\nn\n2\n\n\n\nw\nY\n" | gdisk $drive
    if [[ $drive =~ "nvme" ]]; then
      mkfs.vfat -F32 "${drive}p1"
      UEFI_PART="${drive}p1"
      setup_btrfs "${drive}p2"
    else
      mkfs.vfat -F32 "${drive}1"
      UEFI_PART="${drive}1"
      setup_btrfs "${drive}2"
    fi

    mkdir -p /mnt/install/boot/efi
    mount $UEFI_PART /mnt/install/boot/efi
  else
	echo -e "o\nn\np\n1\n\n\nw" | fdisk $drive # BIOS mode
    if [[ $drive =~ "nvme" ]]; then setup_btrfs "${drive}p1"; else setup_btrfs "${drive}1"; fi
  fi
else
  # user done the partitioning
  setup_btrfs $partition
  if [[ ! -z $UEFI_MODE ]]; then
    mkdir -p /mnt/install/boot/efi
    esppar_guess=$(lsblk | grep -q nvme && echo "/dev/nvme0n1p1" || echo "/dev/sda1")
    read -erp "Enter formatted EF00 ESP partition for EFI: " -i $esppar_guess efi_partition
    mount $efi_partition /mnt/install/boot/efi
  fi
fi

echo "extracting precompiled GentooX image.squashfs to the target partition..."
unsquashfs -f -d /mnt/install/ /mnt/cdrom/image.squashfs
/usr/local/sbin/genfstab -U /mnt/install/ >> /mnt/install/etc/fstab
echo -e "extraction complete.\n"

read -erp "set hostname: " -i "gentoox" hostname
read -erp "set domain name: " -i "haxx.dafuq" domainname
read -erp "set username: " -i "gentoox" username
read -erp "set user password: " -i "gentoox" userpassword
read -erp "set root password: " -i "gentoox" rootpassword

mount -t proc none /mnt/install/proc
mount --rbind /dev /mnt/install/dev
mount --rbind /sys /mnt/install/sys

set +e
cd /mnt/install/
cat <<HEREDOC | chroot .
source /etc/profile && export PS1="(chroot) \$PS1"
if [[ -d /sys/firmware/efi/ ]]; then UEFI_MODE=y; fi
if [[ -z $drive ]]; then drive=$(echo $partition | sed 's/[0-9]\+\$//'); fi

sensors-detect --auto
rc-update add lm_sensors default
rc-update add syslog-ng default

HWTHREADS=\$(getconf _NPROCESSORS_ONLN)
sed -i -r "s/^MAKEOPTS=\"([^\"]*)\"$/MAKEOPTS=\"-j\$HWTHREADS\"/g" /etc/portage/make.conf
sed -i -r "s/^NTHREADS=\"([^\"]*)\"$/NTHREADS=\"\$HWTHREADS\"/g" /etc/portage/make.conf
sed -i "s/-flto=8/-flto=\$HWTHREADS/" /etc/portage/make.conf
#rc-update add zfs-import boot
#rc-update add zfs-mount boot
rc-update delete virtualbox-guest-additions default
rm -f /etc/xdg/autostart/vboxclient.desktop
rm -f /usr/share/applications/avidemux-2.7.desktop

sed -i "s/gentoox/$hostname/g" /etc/conf.d/hostname
sed -i "s/gentoox/$hostname/g" /etc/hosts
sed -i "s/haxx.dafuq/$domainname/g" /etc/hosts
sed -i "s/haxx.dafuq/$domainname/g" /etc/conf.d/net

echo '#!/bin/sh
#echo 0f > /sys/kernel/debug/dri/0/pstate
cpupower frequency-set -g performance
exit 0' > /etc/local.d/my.start
chmod +x /etc/local.d/my.start

touch /swapfile
chattr +C /swapfile
dd if=/dev/zero of=/swapfile count=512 bs=1MiB
chmod 600 /swapfile
mkswap -L MYSWAP /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
echo 'vm.swappiness=10' >> /etc/sysctl.d/local.conf

yes $rootpassword | passwd root
if [[ $username != "gentoox" ]]; then
  usermod --login $username --move-home --home /home/$username gentoox
  groupmod --new-name $username gentoox
fi
yes $userpassword | passwd $username

if [[ ! -z "$UEFI_MODE" ]]; then
  if [[ \$(mokutil --sb-state) == "SecureBoot enabled" ]]; then
    espdev=\$(lsblk -p -no pkname \$(findmnt --noheadings -o source /boot/efi))
    esppar=\$(findmnt --noheadings -o source /boot/efi)
    esp_partnum=\$(echo \${esppar#\$espdev} | tr -d 'p')
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --modules="tpm" --no-nvram
    sbsign --key /usr/src/uefi/MOK.priv --cert /usr/src/uefi/MOK.pem /boot/efi/EFI/gentoo/grubx64.efi --output grubx64.efi.signed
    mv grubx64.efi.signed /boot/efi/EFI/gentoo/grubx64.efi
    cp /usr/share/shim/* /boot/efi/EFI/gentoo/
    mv /boot/efi/EFI/gentoo/BOOTX64.EFI /boot/efi/EFI/gentoo/shimx64.efi
    efibootmgr -c -d \$espdev -p \$esp_partnum -L "GentooX" -l "\EFI\gentoo\shimx64.efi"
  else
    grub-install --target=x86_64-efi
  fi
else
  grub-install --target=i386-pc $drive
fi
grub-mkconfig -o /boot/grub/grub.cfg

#emerge --sync
HEREDOC

sync
umount -l /mnt/install/boot/efi /mnt/install/var /mnt/install/usr/local /mnt/install/tmp /mnt/install/srv /mnt/install/root /mnt/install/opt /mnt/install/home /mnt/install/boot/grub/x86_64-efi /mnt/install/boot/grub/i386-pc /mnt/install/.snapshots /mnt/install 1>/dev/null 2>&1
sync
echo "Installation complete, you may remove the install media and reboot"
