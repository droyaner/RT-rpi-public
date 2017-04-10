#!/bin/bash
usage(){
   echo "build rpi-4.1.y Kernel from https://github.com/raspberrypi/linux.git"
   echo "$(basename $0) [--menuconfig] [--oldconfig config-file]"
   exit 1
}


# 0 - Select Config
case "$#" in
	1) if ![ "$1" == "--menuconfig" ] ; then 
		usage 
	   fi;;
	2) if [ "$1" == "--oldconfig" ]  && [ -f "$2" ]; then 
		CONFIG=$2 
	   else 
   		echo "ERROR: no such file: $2"
		usage 
	   fi;;
	*) usage;;
esac

# 1 - Preparation
wget -q --tries=10 --timeout=30 --spider http://google.com
if [[ $? -eq 0 ]]; then
	echo "Online"
else
	echo "Please make sure you have a valid internet connection"
	exit 1
fi

# 1.1 - Additional packages
sudo apt-get update
sudo apt-get --yes install bc git libncurses5-dev dh-autoreconf gcc make ncurses-dev cmae	# ESSENTIAL-STUFF
sudo apt-get --yes install elfutils libdw-dev libdwarf-dev 					# SYSTEMTAP-REQUIREMENTS
sudo apt-get --yes install python3 python-dev libxml2-dev libxslt-dev libbz2-dev libicu-dev 	# LIBBOOST-REQUIREMENTS
sudo apt-get --yes install tmux vim 								# CUSTOM-USER-STUFF
echo "syntax on" | sudo tee --append ~/.vimrc
#TODO add pyton FLASK 

sudo raspi-config

# 1.2 - Working directory
mkdir ~/xenomai-3-rpi-2
cd ~/xenomai-3-rpi-2

# 1.3 - WiringPi
cd ~/xenomai-3-rpi-2
git clone git://git.drogon.net/wiringPi
cd ~/xenomai-3-rpi-2/wiringPi
./build
cd ~/xenomai-3-rpi-2

# 1.4 - SystemTap
cd ~/xenomai-3-rpi-2
git clone git://sourceware.org/git/systemtap.git
cd ~/xenomai-3-rpi-2/systemtap
./configure
sudo make all
sudo make install

# 1.5 - LibBoost
cd ~/xenomai-3-rpi-2
wget -O boost_1_62_0 https://sourceforge.net/projects/boost/files/boost/1.62.0/boost_1_62_0.tar.gz/download
tar -xvf boost_1_62_0.tar.gz
cd boost_1_62_0
./bootstrap.sh
sudo ./b2 install

# 1.6 - Xenomai sources
cd ~/xenomai-3-rpi-2
git clone https://git.xenomai.org/xenomai-3.git --branch v3.0.2 --depth=1 --progress
cd xenomai-3
git clean -fxd

# 1.7 - Linux sources
cd ~/xenomai-3-rpi-2
git clone https://github.com/raspberrypi/linux.git --branch rpi-4.1.y --depth=1 --progress
cd linux
git clean -fxd

# 2 - Compiling kernel-space components
# 2.1 - Apply patches
cd ~/xenomai-3-rpi-2
xenomai-3/scripts/prepare-kernel.sh --arch=arm --linux=./linux --ipipe=xenomai-3/kernel/cobalt/arch/arm/patches/ipipe-core-4.1.18-arm-4.patch

cd ~/xenomai-3-rpi-2/linux
patch -p1 < ../../patch-xenomai-3-on-bcm-2709.patch

# 2.2 - Kernel configuration
cd ~/xenomai-3-rpi-2/linux

if [ -z $CONFIG ]; then 
	make ARCH=arm bcm2709_defconfig
	make ARCH=arm menuconfig
else
	cp ../../$CONFIG .config
	make ARCH=arm oldconfig
fi


# 2.3 - Kernel and modules building
make -j4 ARCH=arm zImage modules dtbs

# 2.4 - Kernel packing
cd ~/xenomai-3-rpi-2/linux
scripts/mkknlimg arch/arm/boot/zImage ../kernel-linux-4.1.y-xenomai-3.0.img
file ../kernel-linux-4.1.y-xenomai-3.0.img

# 2.5 - Modules packing
mkdir ../modules
rm -R ../modules/*
make -j4 ARCH=arm INSTALL_MOD_PATH=~/xenomai-3-rpi-2/modules modules_install
cd ~/xenomai-3-rpi-2/modules
tar czvf ../modules.tar.gz *
cd ..
rm -Rf modules

# 3 - Compiling user-space components
cd ~/xenomai-3-rpi-2/xenomai-3
./scripts/bootstrap

echo "$CONFIG"  |  grep "*debug*" 
if [ $? == 0 ]; then
	./configure --with-core=cobalt --enable-debug=full --enable-smp --enable-lores-clock --host=arm-bcm2708hardfp-linux-gnueabi CFLAGS="-mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard" LDFLAGS="-mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard"
else
	./configure --with-core=cobalt --enable-smp --disable-doc-install --host=arm-bcm2708hardfp-linux-gnueabi CFLAGS="-mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard" LDFLAGS="-mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard"
fi

rm -Rf ../xenomai-userspace
mkdir ../xenomai-userspace
make
make DESTDIR=$(pwd)/../xenomai-userspace install

cd ../xenomai-userspace
tar czvf ../xenomai-userspace.tar.gz *
cd usr/xenomai/include
tar czvf ../../../../xenomai-headers.tar.gz *
cd ../lib
tar czvf ../../../../xenomai-libs.tar.gz *.a


cp ~/xenomai-3-rpi-2/linux/arch/arm/boot/dts/bcm2709-rpi-2-b.dtb /tmp
cp ~/xenomai-3-rpi-2/kernel-linux-4.1.y-xenomai-3.0.img /tmp
cp ~/xenomai-3-rpi-2/modules.tar.gz /tmp
cp ~/xenomai-3-rpi-2/xenomai-userspace.tar.gz /tmp

sudo cp /tmp/kernel-linux-4.1.y-xenomai-3.0.img /boot/
sudo cp /tmp/bcm2709-rpi-2-b.dtb /boot/

echo "kernel=kernel-linux-4.1.y-xenomai-3.0.img" | sudo tee --append /boot/config.txt
echo "hdmi_force_hotplug=1" | sudo tee --append /boot/config.txt
echo "hdmi_mode=19 # 720p 50Hz" | sudo tee --append /boot/config.txt

cd /

sudo tar xzvf /tmp/modules.tar.gz
sudo tar xzvf /tmp/xenomai-userspace.tar.gz
echo "/usr/xenomai/lib/" | sudo tee /etc/ld.so.conf.d/xenomai.conf
sudo ldconfig -v
sync
echo "PRESS ENTER FOR REBOOT"
read ENTER
sudo reboot
