.PHONY: all build check clean initramfs kernel

NIX       ?= nix
NIX_FLAGS ?= --extra-experimental-features 'nix-command flakes'
NIX_OUT   ?= out

all: build

build: ${NIX_OUT}/initramfs ${NIX_OUT}/kernel

check:
	${NIX} ${NIX_FLAGS} flake check .

clean:
	rm -rf ${NIX_OUT}

initramfs: ${NIX_OUT}/initramfs

kernel: ${NIX_OUT}/kernel

${NIX_OUT}:
	mkdir -p $@

${NIX_OUT}/initramfs: flake.nix flake.lock init.sh | ${NIX_OUT}
	${NIX} ${NIX_FLAGS} build .#initramfs --out-link ${NIX_OUT}/initramfs

${NIX_OUT}/kernel: flake.nix flake.lock | ${NIX_OUT}
	${NIX} ${NIX_FLAGS} build .#kernel --out-link ${NIX_OUT}/kernel

