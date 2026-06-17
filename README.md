# OpenWrt Builder for GL.iNet Beryl AX / GL-MT3000

This repository builds a reproducible vanilla OpenWrt image for the
GL.iNet Beryl AX / GL-MT3000 travel router.

The Beryl AX is a fantastic little machine: compact, powerful, USB-C
powered, Wi-Fi 6 capable, and equipped with useful travel-router hardware
such as dual Ethernet ports and USB 3.0. It is exactly the kind of device
that deserves a long, useful life beyond the default vendor firmware.

## Why this project exists

GL.iNet’s firmware is convenient and beginner-friendly, but it is also a
vendor-custom OpenWrt distribution. For my own travel-router setup, I want
something closer to upstream OpenWrt:

- reproducible firmware builds;
- fewer vendor-specific components;
- a clean LuCI/OpenWrt experience;
- packages selected for my own use case;
- easier auditing and long-term maintenance;
- built-in support for my travel setup, including an external USB Wi-Fi
  adapter for better upstream reception.

This project is not meant to criticize the Beryl AX hardware. Quite the
opposite: the GL-MT3000 is a great small router, and this repository exists
because I want to keep using it with a clean, maintainable OpenWrt image.

## Target use case

My main use case is travel networking:

- use the Beryl AX as a secure personal router;
- connect the router to hotel, Airbnb, café, or hotspot Wi-Fi;
- use an external USB Wi-Fi adapter, such as the Alfa AWUS036ACM, as the
  upstream/client radio;
- keep the internal Wi-Fi radios for my own trusted devices;
- manage roaming and captive-portal-style uplinks with OpenWrt packages
  such as Travelmate;
- optionally run WireGuard or another VPN client on the router.

## What this repository builds

The GitHub Actions workflow downloads the official OpenWrt ImageBuilder
for the GL-MT3000 target and produces a custom sysupgrade image with my
preferred packages preinstalled.

The image is intended to include:

- LuCI;
- Travelmate;
- WireGuard support;
- USB utilities;
- MediaTek USB Wi-Fi drivers for the AWUS036ACM / MT7612U path;
- a small first-boot configuration for travel-router defaults.

## What this project is not

This project does not try to recreate the GL.iNet web interface.

The GL.iNet UI and utilities are tightly coupled to GL.iNet’s own firmware
stack. If you want the GL.iNet web UI, the better option is to use official
GL.iNet firmware. If you want a clean upstream OpenWrt system, this project
takes the vanilla OpenWrt route instead.

## Flashing note

When migrating from GL.iNet firmware to vanilla OpenWrt, use the OpenWrt
sysupgrade image for the GL-MT3000 and do not keep the old vendor settings.

Always connect by Ethernet while flashing, keep a known-good recovery path,
and make sure you understand the OpenWrt device instructions before writing
firmware to the router.

## Status

Personal project. Use at your own risk.
