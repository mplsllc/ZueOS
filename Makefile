# XueOS build farm — master pipeline orchestrator
#
# Targets:
#   make build-iso   Build the XueOS live ISO (requires root; auto-sudos).
#   make update-repo Publish one or more .deb packages to the apt repo.
#                     Usage: make update-repo DEBS="/path/a.deb /path/b.deb"
#   make clean       Remove temporary build directories and any stray
#                     chroot mounts left behind by a failed build.
#   make help        Show this list.

SHELL := /bin/bash
.DEFAULT_GOAL := help

ROOT_DIR    := $(shell cd "$(dir $(lastword $(MAKEFILE_LIST)))" && pwd)
CONFIG      := $(ROOT_DIR)/config/build.conf
WORK_DIR    := $(ROOT_DIR)/work
CHROOT_DIR  := $(WORK_DIR)/chroot

.PHONY: help build-iso update-repo clean

help:
	@echo "XueOS build farm"
	@echo ""
	@echo "  make build-iso              Build the ISO (sudo required)"
	@echo "  make update-repo DEBS=...   Publish .deb package(s) to apt.mp.ls"
	@echo "  make clean                  Remove work dir + stray chroot mounts"

build-iso:
	@echo ">> Building XueOS ISO (this needs root for debootstrap/chroot)..."
	sudo "$(ROOT_DIR)/build-iso.sh"
	@echo ">> Done. See config/build.conf WEB_PUBLISH_DIR for the published ISO."

update-repo:
ifndef DEBS
	$(error Usage: make update-repo DEBS="/path/to/package.deb [more.deb ...]")
endif
	@echo ">> Publishing $(DEBS) to the apt repository..."
	"$(ROOT_DIR)/scripts/publish-deb.sh" $(DEBS)

clean:
	@echo ">> Cleaning up temporary build state..."
	@# Unmount any chroot virtual filesystems a failed build left mounted,
	@# deepest paths first so parent mounts don't refuse to unmount.
	@if mount | grep -q "$(CHROOT_DIR)"; then \
		echo "   unmounting stray chroot mounts under $(CHROOT_DIR)"; \
		mount | awk -v d="$(CHROOT_DIR)" '$$3 ~ "^"d {print $$3}' | sort -r | \
			xargs -r -n1 sudo umount -lf ; \
	fi
	sudo rm -rf --one-file-system "$(WORK_DIR)"
	@mkdir -p "$(WORK_DIR)"
	@echo ">> Clean."
