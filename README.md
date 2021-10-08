# hp-scan-monitor

The firmware in HP all-in-one printer/scanners does not support network file systems (SMB, NFS, etc.). 
That means any scanned files must be saved to a PC (over USB or Ethernet) or a USB thumb drive (disk-on-key). 
On the other hand, the printer's console (built-in screen and keyboard) often has a "scan to PC" function
that can be used to initiate a scan. But the destination must be a computer that has identified itself as
being able to receive scan commands. Even though the scanner initiates the scan, the destination computer
drives the whole scanning process. That means the computer must be running HP scan software and must be
online during the scan. This is not very flexible or convenient for anyone who uses more than one computer
or who wants to scan a document while their laptop is not running.

This monitor solves the problem by listening for scan requests from the console of an HP scanner. It
understands the HP scanner protocol and can replace the complicated, proprietary scanning software
distributed by HP. It is written in bash, a simple, portable shell scripting language, that is available
on a wide range of systems, and does not incur a high computational overhead (you don't need a powerful
CPU to run it).

The monitor is designed to run on a headless NAS (network attached storage) server. In my house, my NAS
server is a cheap SBC (single board computer) with an ARM Cortex-A9 CPU that runs Ubuntu. Many other NAS
boxes that are sold commercially now allow users to install their own apps and services in a similar
manner. This allows me to save incoming scanned files in a shared directory on the network.

## Known Issues

The script is quite simple and not fully featured. It can only save JPEG files at a single resolution and
source document size. It can only save a single document per scan. There are probably many other features
that other people would like to use, that this does not do. There is no fundamental limitation in the
design that prevents me from doing these things, only time.
