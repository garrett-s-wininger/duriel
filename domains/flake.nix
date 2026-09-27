{
  description = "Duriel Hypervisor Domains";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/26.05";

  outputs = {self, nixpkgs}:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      packages.${system} = {
          initramfs = pkgs.runCommand "duriel-initramfs.cpio" {
            nativeBuildInputs = [pkgs.cpio pkgs.coreutils pkgs.findutils];
          } ''
            mkdir -p root/dev root/proc root/sys
            install -D -m 0755 ${pkgs.pkgsStatic.busybox}/bin/busybox root/bin/busybox
            install -D -m 0755 ${./init.sh} root/init

            find root -exec touch --date=@1 {} +

            (
              cd root
              find . -print | LC_ALL=C sort | cpio --quiet --reproducible --owner=0:0 -o -H newc
            ) > "$out"
        '';

        kernel = pkgs.linuxPackages.kernel;
      };
    };
}
