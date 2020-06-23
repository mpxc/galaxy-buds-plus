# galaxy-buds-plus

This repository contains a Perl script - the simple interface to Samsung Galaxy Buds Plus device.

I recently bought this headset and noticed it gave me a Serial Port when connecting with BlueZ on Linux (yay!).
At first, I just wanted to see if its possible to change a few settings from my laptop (without having to connect the headset back to the phone).
Poking the raw /dev/rfcomm0 device in C was fun, but Net:Bluetooth made it much easier - and here we are.

This script is a product of reversing an undocumented protocol, its probably full of bugs :^)

## Usage

Download this repository and run:

```bash
./budsplus.pl --help
```

Since its written in Perl, it should be quite portable.

## Caveats

* The output from the script is not very pretty, its meant to be called from other scripts and such.
* Not all messages/options are decoded, shown or supported (this will probably change in the future).
* Stuff like volume control and voice assistant will require a daemon, which leads me to...
 
## TODO/Work in progress

* Detailed protocol specification
* Cross-platform systray application (QT5)
