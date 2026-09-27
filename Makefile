.PHONY: aarch64-vars all build clean domain-assets domains efi-dirs riscv-efi riscv-vars run run-aarch64 run-native run-riscv

HYPERVISOR_OUT ?= hypervisor/zig-out/bin

EDK2_SOURCE ?= /usr/local/src/edk2
GENFW       ?= ${EDK2_SOURCE}/BaseTools/BinWrappers/PosixLike/GenFw

UEFI_BOOT_DIRECTORY        ?= ${UEFI_DIST_DIRECTORY}/esp/EFI/BOOT
UEFI_DIRECTORY             ?= /usr/share/OVMF
UEFI_DIST_DIRECTORY        ?= dist
UEFI_FIRMWARE_AARCH64_CODE ?= ${UEFI_DIRECTORY}/aarch64/QEMU_EFI.fd
UEFI_FIRMWARE_AARCH64_VARS ?= ${UEFI_DIRECTORY}/aarch64/QEMU_VARS.fd
UEFI_FIRMWARE_RISCV_CODE   ?= ${UEFI_DIRECTORY}/riscv64/RISCV_VIRT_CODE.fd
UEFI_FIRMWARE_RISCV_VARS   ?= ${UEFI_DIRECTORY}/riscv64/${RISCV_VARS}
UEFI_FIRMWARE_X64          ?= ${UEFI_DIRECTORY}/x64/OVMF.4m.fd

DOMAIN_ESP_DIRECTORY ?= ${UEFI_DIST_DIRECTORY}/esp/domains/placeholder
DOMAIN_INITRAMFS     ?= domains/out/initramfs
DOMAIN_KERNEL        ?= domains/out/kernel/bzImage

AARCH64_VARS      ?= QEMU_VARS.fd
AARCH64_VARS_PATH ?= ${UEFI_DIST_DIRECTORY}/${AARCH64_VARS}

RISCV_VARS      ?= RISCV_VIRT_VARS.fd
RISCV_VARS_PATH ?= ${UEFI_DIST_DIRECTORY}/${RISCV_VARS}

QEMU_AARCH64 ?= qemu-system-aarch64
QEMU_RISCV64 ?= qemu-system-riscv64
QEMU_X64     ?= qemu-system-x86_64

QEMU_FLAGS_COMMON  ?= -m 256M -serial stdio -display none
QEMU_FLAGS_AARCH64 ?= --machine virt \
	-cpu cortex-a72 \
	-drive if=pflash,format=raw,readonly=on,file=${UEFI_FIRMWARE_AARCH64_CODE} \
	-drive if=pflash,format=raw,file=${AARCH64_VARS_PATH} \
	-boot menu=on,splash-time=0 \
	-drive if=none,id=esp,format=raw,file=fat:rw:${UEFI_DIST_DIRECTORY}/esp \
	-device qemu-xhci,id=xhci \
	-device usb-storage,drive=esp
QEMU_FLAGS_NATIVE  ?= --enable-kvm -cpu host
QEMU_FLAGS_RISCV   ?= --machine virt,pflash0=pflash0,pflash1=pflash1 \
	-blockdev node-name=pflash0,driver=file,read-only=on,filename=${UEFI_FIRMWARE_RISCV_CODE} \
	-blockdev node-name=pflash1,driver=file,filename=${RISCV_VARS_PATH} \
	-boot menu=on,splash-time=0 \
	-drive if=none,id=esp,format=raw,file=fat:rw:${UEFI_DIST_DIRECTORY}/esp \
	-device virtio-blk-device,drive=esp
QEMU_FLAGS_X64     ?= --bios ${UEFI_FIRMWARE_X64} --machine q35 -drive format=raw,file=fat:rw:${UEFI_DIST_DIRECTORY}/esp

all: build

build:
	$(MAKE) -C hypervisor build

clean:
	rm -rf dist
	$(MAKE) -C domains clean
	$(MAKE) -C hypervisor clean

${DOMAIN_ESP_DIRECTORY}:
	mkdir -p $@

domain-assets: domains | ${DOMAIN_ESP_DIRECTORY}
	cp ${DOMAIN_INITRAMFS} ${DOMAIN_ESP_DIRECTORY}/initramfs.cpio
	cp ${DOMAIN_KERNEL} ${DOMAIN_ESP_DIRECTORY}/kernel.bzImage

domains:
	$(MAKE) -C domains build

${UEFI_BOOT_DIRECTORY}:
	mkdir -p $@

efi-dirs: ${UEFI_BOOT_DIRECTORY}

${AARCH64_VARS_PATH}: ${UEFI_FIRMWARE_AARCH64_VARS} | ${UEFI_BOOT_DIRECTORY}
	cp $< $@

aarch64-vars: ${AARCH64_VARS_PATH}

riscv-efi: build efi-dirs
	${GENFW} -e UEFI_APPLICATION -o ${UEFI_BOOT_DIRECTORY}/BOOTRISCV64.EFI ${HYPERVISOR_OUT}/bootriscv64

${RISCV_VARS_PATH}: ${UEFI_FIRMWARE_RISCV_VARS} | ${UEFI_BOOT_DIRECTORY}
	cp $< $@

riscv-vars: ${RISCV_VARS_PATH}

run: run-native

run-aarch64: aarch64-vars build efi-dirs
	cp ${HYPERVISOR_OUT}/bootaa64.efi ${UEFI_BOOT_DIRECTORY}/BOOTAA64.EFI
	${QEMU_AARCH64} ${QEMU_FLAGS_COMMON} ${QEMU_FLAGS_AARCH64}

run-native: build efi-dirs
	cp ${HYPERVISOR_OUT}/bootx64.efi ${UEFI_BOOT_DIRECTORY}/BOOTX64.EFI
	${QEMU_X64} ${QEMU_FLAGS_COMMON} ${QEMU_FLAGS_X64} ${QEMU_FLAGS_NATIVE}

run-riscv: riscv-efi riscv-vars
	${QEMU_RISCV64} ${QEMU_FLAGS_COMMON} ${QEMU_FLAGS_RISCV}
