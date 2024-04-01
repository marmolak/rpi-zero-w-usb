#!/usr/bin/env bash
#
# Based on:
# https://magpi.raspberrypi.com/articles/pi-zero-w-smart-usb-flash-drive
# https://forum-raspberrypi.de/forum/thread/36132-usb-gadget-mass-storage-emulation/

if [ $UID -ne 0 ]; then
    echo "This script must be run as root user."
    exit 1
fi

set -x
set -e

declare -x -r USB_FILE="usbdisk.img"

dd if=/dev/zero of="/${USB_FILE}" bs=1 count=0 seek=20480M

(
echo x # switch to eXpert mode
echo s # set sectors/track
echo 8 # g_mass_storage uses a sector size of 512 bytes, so 8 sectors/track will give us 4096 bytes per track
echo h # set number of heads
echo 16
echo c # set number of cylinders
echo 327680 # 20GB = 20971520 kb / 64 tracks = 327680 cylinders
echo r # return to normal mode
echo n # new partition
echo p # primary
echo 1
echo   # accept default
echo   # accept default
echo t # new partition is created by default as a Linux partition. Since you want to use the gadget with a Windows host, you should change the partition type to FAT32
echo b
echo a # partition should be set as active or USB drive will not be attached to the file-system when plugged in.
echo p # print new partition table to verify..
echo w # Write changes
) | fdisk "/${USB_FILE}"

DISK=$(losetup --show --find -o $((2048*512)) "/${USB_FILE}")
mkfs -t vfat -v "${DISK}" -n usbdisk
losetup -d "${DISK}"

apt update
apt dist-upgrade -y
apt install tmux mosh vim mc samba winbind python3-pip -y

pip3 install watchdog

# setup
echo -e "\ndtoverlay=dwc2" >> /boot/config.txt
echo -e "\ndwc2" >> /etc/modules

mkdir -p /mnt/usb_share

echo "/${USB_FILE} /mnt/usb_share vfat offset=1048576,users,umask=000 0 2" >> /etc/fstab


cat << 'EOF' >> /etc/samba/smb.conf
[usb]
browseable = yes
path = /mnt/usb_share
guest ok = yes
read only = no
create mask = 777
EOF

pushd /usr/local/share

cat << 'EOF' > usb_share.py
#!/usr/bin/python3
import time
import os
from watchdog.observers import Observer
from watchdog.events import *

CMD_MOUNT = 'modprobe g_mass_storage file=/usbdisk.img stall=0 ro=1 removable=1 idVendor=0x0781 idProduct=0x5572 bcdDevice=0x011a iManufacturer="SanDisk" iProduct="Cruzer Switch" iSerialNumber=1234567890'
CMD_UNMOUNT = "modprobe -r g_mass_storage"
CMD_SYNC = "sync"

WATCH_PATH = "/mnt/usb_share"
ACT_EVENTS = [DirDeletedEvent, DirMovedEvent, FileDeletedEvent, FileModifiedEvent, FileMovedEvent]
ACT_TIME_OUT = 30

class DirtyHandler(FileSystemEventHandler):
    def __init__(self):
        self.reset()

    def on_any_event(self, event):
        if type(event) in ACT_EVENTS:
            self._dirty = True
            self._dirty_time = time.time()

    @property
    def dirty(self):
        return self._dirty

    @property
    def dirty_time(self):
        return self._dirty_time

    def reset(self):
        self._dirty = False
        self._dirty_time = 0
        self._path = None


os.system(CMD_MOUNT)

evh = DirtyHandler()
observer = Observer()
observer.schedule(evh, path=WATCH_PATH, recursive=True)
observer.start()

try:
    while True:
        while evh.dirty:
            time_out = time.time() - evh.dirty_time

            if time_out >= ACT_TIME_OUT:
                os.system(CMD_UNMOUNT)
                time.sleep(1)
                os.system(CMD_SYNC)
                time.sleep(1)
                os.system(CMD_MOUNT)
                evh.reset()

            time.sleep(1)

        time.sleep(1)

except KeyboardInterrupt:
    observer.stop()

observer.join()
EOF

chmod +x usb_share.py

popd


pushd /etc/systemd/system

cat << 'EOF' > usbshare.service
[Unit]
Description=USB Share Watchdog

[Service]
Type=simple
ExecStart=/usr/local/share/usb_share.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

popd

mount -a

systemctl daemon-reload
systemctl enable usbshare.service
systemctl start usbshare.service
systemctl restart smbd.service

echo "If you see this, you should restart now."
