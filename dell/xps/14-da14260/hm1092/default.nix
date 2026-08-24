{
  stdenv,
  lib,
  kernel,
  kernelModuleMakeFlags,
  fetchFromGitHub,
}:

# Himax HM1092 IR sensor driver, for the Windows-Hello camera on the same
# SVP7500 bridge as the RGB sensor. There is no in-tree counterpart:
# drivers/media/i2c/hm1092.c does not exist in mainline, so this stays vendored
# indefinitely rather than carrying a "drop once upstream" note like the
# packages from nixpkgs #542085.
#
# The driver publishes V4L2_CID_LINK_FREQ = 180480000, the DDR clock. Earlier
# revisions published 360960000, which is the correct per-lane MIPI bit rate but
# twice the value V4L2 asks for; ISys then programmed the CSI-2 D-PHY at
# ~721 Mbps against a sensor transmitting ~361, so the clock lane came up and no
# data packet ever framed. That produced zero SOF indefinitely and was long
# mistaken for a bridge firmware block (intel/vision-drivers#37, retracted
# 2026-07-25).
#
# hm1092 reaches cvs_send_mipi_ir_config through a weak reference, to ask the
# bridge to configure port-2 forwarding. Only the fix pack's fork of intel_cvs
# exports it, which is why ir-camera.nix ships ./intel-cvs-ir in place of the
# base profile's plain intel-cvs; the reference being weak means the module
# still loads without it, logging "intel_cvs symbol unavailable; port-2
# forwarding NOT configured". Note that per the fix pack's own IR-FINDINGS.md
# that payload was tested both ways and is NOT what made IR work -- the
# LINK_FREQ correction was -- so treat the pairing as "how this was verified",
# not a proven requirement.
#
# depmod does record weak undefined symbols (unlike modpost, which omits them
# from the modinfo `depends` string), so modprobe pulls intel_cvs in first when
# both live in one tree. NixOS aggregates all of boot.extraModulePackages into a
# single tree, so that holds by construction.
stdenv.mkDerivation (finalAttrs: {
  pname = "hm1092";
  # dkms.conf declares PACKAGE_VERSION="1.0"; the rev is an untagged master.
  version = "1.0-unstable-2026-07-30";

  src = fetchFromGitHub {
    owner = "jibsta210";
    repo = "svp7500-camera-fix-pack";
    rev = "5d40327c217f4279b235073f1cd9f8e40a9b4a20";
    hash = "sha256-6Gf2FVy7VItyKlwquKM0wTFycl9KBmhF55UnuWTctEg=";
  };

  # The repo ships several DKMS trees; this one is self-contained (three files,
  # only mainline kernel headers, no shared includes with its siblings).
  sourceRoot = "${finalAttrs.src.name}/dkms/hm1092-1.0";

  hardeningDisable = [
    "pic"
    "format"
  ];

  nativeBuildInputs = kernel.moduleBuildDependencies;

  # Drive kbuild directly rather than through the bundled Makefile's targets:
  # its `all` recipe passes CC=clang LLVM=1 to the sub-make, which beats
  # anything given on the command line and fails against a gcc-built kernel,
  # and it has no install target at all. Passing -C here is the same shape
  # nixpkgs' gasket module uses, and keeps the stdenv phases (and their
  # flag-array handling) intact instead of overriding them.
  makeFlags = kernelModuleMakeFlags ++ [
    "KERNELRELEASE=${kernel.modDirVersion}"
    "-C"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "M=$(PWD)"
  ];

  buildFlags = [ "modules" ];

  installFlags = [ "INSTALL_MOD_PATH=${placeholder "out"}" ];

  installTargets = [ "modules_install" ];

  enableParallelBuilding = true;

  meta = {
    description = "Himax HM1092 infrared camera sensor driver";
    homepage = "https://github.com/jibsta210/svp7500-camera-fix-pack";
    license = lib.licenses.gpl2Only;
    # The driver carries no LINUX_VERSION_CODE fallbacks at all, so an older
    # kernel fails to compile rather than degrading. The floor comes from
    # v4l2_subdev_state_get_format and .init_state in v4l2_subdev_internal_ops,
    # both 6.8; the void-returning i2c .remove it also uses is older still
    # (6.1). Built here against 6.12, 6.18 and 7.1.
    broken = kernel.kernelOlder "6.8";
    platforms = [ "x86_64-linux" ];
  };
})
