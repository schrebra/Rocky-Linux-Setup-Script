# Rocky-Linux-Setup-Script

For Rocky Linux 10.2 Gnome or Gnome Lite

https://rockylinux.org/download

# 🚀 Rocky Linux GNOME Desktop Setup

A **one-click automation script** designed to transform a stock Rocky Linux (or RHEL-based) installation into a polished, high-performance desktop environment using **GNOME Shell 49+**.

It automates system tuning, dependency management, and extension installation to create a clean, "Windows-style" taskbar experience without manual configuration drift.

---

## 📋 Table of Contents

- [✨ Features](#-features)
- [🎯 Who Is This For?](#-who-is-this-for)
- [🤔 Why Do You Need It?](#-why-do-you-need-it)
- [📦 What Does This Script Actually Do?](#-what-does-this-script-actually-do)
- [🚨 Prerequisites](#-prerequisites)
- [⚡ Quick Start](#-quick-start)
- [🛠️ Advanced Usage (Debug Mode)](#️-advanced-usage-debug-mode)
- [❓ Troubleshooting](#-troubleshooting)

---

## ✨ Features

- **🏎️ Performance Tuning**: Forces `performance` power profiles and creates a persistent systemd enforcement service to prevent throttling on boot.
- **🖥️ Modern Taskbar**: Installs & configures **Dash to Panel**, **Arc Menu**, and **No Overview** for a productive, Windows-like workflow.
- **🌙 Dark Mode First**: Enforces system-wide dark styling and standard window controls (Min/Max/Close).
- **🔄 Idempotent**: Safe to run multiple times; skips configuration if settings are already applied.
- **🔍 Debug Support**: Built-in verbose tracing mode (`DEBUG=1`) for troubleshooting edge cases.

## 🎯 Who Is This For?

1.  **Developers & DevOps Engineers**: Who want a consistent, repeatable Linux desktop environment that can be re-provisioned in minutes.
2.  **GNOME Power Users**: Who prefer the stability of upstream GNOME but miss a functional taskbar (Dock) and traditional app menus without navigating the "Activities" overview constantly.
3.  **Rocky Linux / RHEL / AlmaLinux Users**: Specifically targeting enterprise-grade distros that ship a barebones GNOME configuration by default.

## 🤔 Why Do You Need It?

Configuring GNOME properly can be tedious. You often find yourself:
1.  Manually searching the web for extensions compatible with your exact GNOME version.
2.  Editing complex JSON structures in `dconf` blindly.
3.  Fighting with `power-profiles-daemon` which defaults to "balanced" (sluggish) on servers/workstations.

This script codifies that setup into **one command**. It ensures your environment looks exactly how you want it, maximizes CPU performance for builds/compiles, and removes visual clutter.

---

## 📦 What Does This Script Actually Do?

When you execute this script, it performs the following operations in order:

### 1. System Validation & Dependencies
- Detects current **GNOME Shell Version**.
- Ensures core tools (`curl`, `jq`, `unzip`, `python3`) are installed via `dnf`.

### 2. System Performance Overclocking
- Probes D-Bus for **PowerProfiles** support.
- Sets profile to `performance`.
- Creates `/etc/systemd/system/enforce-performance.service` to ensure this setting persists across reboots (even if the daemon resets it).

### 3. Desktop Environment Polish
- **Window Controls**: Rearranges title bar buttons to `[—] [□] [x]` (Standard Layout).
- **Color Scheme**: Forces `prefer-dark`.

### 4. Extension Management (The Core Feature)
Automatically fetches and installs:
| Extension | Purpose |
| :--- | :--- |
| **[Dash-to-Panel](https://extensions.gnome.org/extension/1160/dash-to-panel/)** | Merges dock & top bar into a single **bottom taskbar**. Configured for center icons + tray on right. |
| **[Arc Menu](https://extensions.gnome.org/extension/3628/arcmenu/)** | Adds a Start-menu style launcher, replacing the hidden Activities grid. |
| **[No Overview](https://extensions.gnome.org/extension/4099/no-overview/)** | Pressing `Super` key now opens the App Menu instead of the full-screen workspace overview. |

### 5. Idempotent Configuration
- Applies fine-tuned `dconf` layouts for the panel (anchors, sizes, element positions).
- **Note**: Terminal theme configurations are intentionally **excluded** from this script to respect user preferences.

---

## 🚨 Prerequisites

- **OS**: Rocky Linux 9+, RHEL 9, AlmaLinux 9, or Fedora Workstation.
- **Desktop**: GNOME Shell (Tested on v49+).
- **User**: Must be run as a **non-root user** with `sudo` privileges.
- **Session**: Must be run inside an active graphical session (local GUI or remote X/Wayland).

---

## ⚡ Quick Start

**1. Clone or download the script:**
```bash
git clone [https://github.com/YOUR_USER/rocky-gnome-setup.git](https://github.com/YOUR_USER/rocky-gnome-setup.git)
cd rocky-gnome-setup
chmod +x setup.sh
