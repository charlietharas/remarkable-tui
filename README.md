# remarkable-tui

Usage:
Requires reMarkable tablet running with USB connected and USB web interface enabled (settings > general > storage). Requires [RCU](https://www.davisr.me/projects/rcu/) installed. Requires having the tablet's USB connection available as an ssh host (configured e.g. in `~/.ssh/config`). For example:
```
host remarkable-usb
  Hostname 10.11.99.1
  User root
  Port 22
  IdentityFile ~/.ssh/id_rsa_remarkable
```
Note that this example requires having an ssh key configured on the tablet, which is straightforward to set up and recommended.

On load the script take a moment to build the initial cache of document metadata.

Flags:
- `--refresh-cache | r`: refresh document metadata cache

See script for more customizability options.

