{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkIf
    mkOption
    types
    versionAtLeast
    versionOlder
    ;

  cfg = config.hardware.dell-xps-14-da14260.irCamera;

  kernelVersion = config.boot.kernelPackages.kernel.version;
in
{
  options = {
    hardware.dell-xps-14-da14260.irCamera = {
      enable = mkOption {
        default = false;
        type = types.bool;
        description = ''
          Enable the HM1092 infrared camera (the Windows Hello sensor), for use
          with a face-authentication stack such as Howdy.

          This is opt-in because it needs a patched kernel: ipu-bridge only
          learned the sensor's ACPI ID after Linux 7.2, so on anything older the
          profile adds a single-entry kernel patch, and that means building the
          kernel locally rather than substituting it from the binary cache.

          Enabling it also swaps the vendored intel_cvs bridge module for the
          fix pack's fork of it (intel-cvs-ir), which exports the
          cvs_send_mipi_ir_config the sensor driver needs to get CSI-2 port-2
          forwarding configured; the plain intel/vision-drivers build exports
          no symbols and leaves every IR frame dark.

          The sensor shows up as `/dev/ir-camera`, a stable symlink to whichever
          ISYS capture node it lands on for this boot. Point a face-auth
          configuration at that rather than at a `/dev/videoN` number, which is
          not stable across reboots.

          An assertion restricts this to 7.1.x. Below 7.1 int3472 does not
          register the illuminator as a LED device, so there is nothing for the
          udev rule to grant and every frame comes back dark. From 7.2 the
          in-tree cvs driver routes the sensor graph through its own V4L2 subdev
          instead of the out-of-tree intel_cvs this was tested against, which is
          untested rather than known-broken -- see the assertion message.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        # The illuminator LED classdev only exists from 7.1: int3472's
        # discrete.c gained the INT3472_GPIO_TYPE_STROBE -> "ir_flood" mapping
        # and skl_int3472_register_led() there (absent at 7.0). Below that the
        # udev rule matches nothing and every frame comes back dark, which
        # looks exactly like broken hardware.
        assertion = versionAtLeast kernelVersion "7.1" && versionOlder kernelVersion "7.2";
        message = ''
          hardware.dell-xps-14-da14260.irCamera is enabled, but the configured
          kernel is ${kernelVersion}. The supported window is 7.1.x.

          Below 7.1: int3472 has no INT3472_GPIO_TYPE_STROBE -> "ir_flood"
          mapping and does not call skl_int3472_register_led(), so the
          illuminator is never exposed as a LED device. The udev rule below then
          matches nothing, the illuminator never fires, and every frame comes
          back too dark to find a face in.

          From 7.2: the in-tree drivers/media/i2c/cvs driver replaces the
          out-of-tree intel_cvs this was verified against, and routes the sensor
          graph through its own V4L2 subdev -- the same topology change that
          broke the RGB camera HAL until it was made CVS-aware.

          This is untested, not known-broken: the in-tree driver sends
          HOST_SET_MIPI_CONFIG itself from csi_set_link_cfg(), taking the link
          frequency from the sensor's own control, and 06CB:0701 is not quirked
          out of that path -- so the bridge configuration hm1092 used to request
          via cvs_send_mipi_ir_config may simply happen anyway.

          The one mechanism that might genuinely block it: ipu-bridge finishes
          ipu_bridge_instantiate_ivsc() with set_secondary_fwnode() on the
          shared csi_dev, once per sensor and overwriting unconditionally, while
          the in-tree cvs models exactly one remote. Both sensors sit behind the
          same INTC10E1:00, so only one can own that fwnode. Whether that
          affects the IR sensor depends on its ACPI _DEP, which has not been
          read off a DSDT yet.

          Pin a kernel older than 7.2, or disable this option. If you want to
          help settle it, say so upstream rather than editing this assertion out
          blind -- the failure mode to watch for is the RGB camera regressing.
        '';
      }
    ];

    # ipu-bridge only walks ipu_supported_sensors[], so an unlisted ACPI HID
    # never gets a software node built for it. The i2c client itself still
    # enumerates -- that comes from ACPI I2cSerialBus, independently -- but
    # without the fwnode graph the IPU7 ISYS async notifier has no port to match
    # it against, so it probes and then never joins the media graph. The entry
    # is in mainline master but landed after 7.2, so it has to be backported on
    # anything older, including 7.2 itself. This rebuilds the kernel, which is
    # why the whole option is opt-in.
    boot.kernelPatches = [
      {
        name = "ipu-bridge-himx1092";
        patch = ./himx1092-ipu-bridge.patch;
      }
    ];

    # The sensor driver. It has no in-tree counterpart, so unlike the packages
    # vendored from nixpkgs #542085 this one has no upstream to defer to.
    #
    # intel-cvs-ir REPLACES the base profile's intel-cvs (default.nix drops
    # its entry when this option is enabled -- same intel_cvs.ko name, only
    # one may be in the tree). It is the fix-pack fork of the same driver,
    # and it is what makes this option functional: hm1092 requests port-2
    # forwarding through a weak reference to cvs_send_mipi_ir_config, which
    # only the fork exports -- the plain intel/vision-drivers rev exports
    # nothing, the reference resolves NULL, and every frame stays dark. This
    # is also why the base profile's `< 7.2` intel-cvs gate genuinely bounds
    # this option: the IR path needs an out-of-tree intel_cvs, and from 7.2
    # the in-tree cvs driver owns the device instead (see the assertion).
    boot.extraModulePackages = [
      (config.boot.kernelPackages.callPackage ./hm1092 { })
      (config.boot.kernelPackages.callPackage ./hm1092/intel-cvs-ir { })
    ];

    # hm1092 autoloads off the i2c adapter via its ACPI modalias, on a different
    # trigger from the softdep in default.nix -- which orders the bridge stack
    # only ahead of intel_ipu7, not ahead of the sensor. That matters because
    # hm1092's probe is deliberately one-shot: hm1092_check_chip_id() returns
    # -ENODEV for any I2C failure rather than -EPROBE_DEFER (retries were found
    # to wedge the USB bus), and its regulator/clock lookups are "optional", so
    # they fall back to NULL instead of deferring. Probe before INT3472 has
    # registered dvdd and the 19.2 MHz clock and the sensor is simply dead until
    # someone re-binds it by hand. Order it explicitly.
    boot.extraModprobeConfig = ''
      softdep hm1092 pre: intel_skl_int3472_discrete intel_cvs
    '';

    # The IR flood illuminator is exposed by INT3472 as a LED class device, so
    # it has no /dev node and udev's GROUP=/MODE= cannot reach it -- only the
    # `brightness` sysfs attribute matters, and it is root-only by default.
    # (The upstream fix-pack rule calls /bin/chgrp and /bin/chmod, which do not
    # exist on NixOS and make the rule a silent no-op, hence the store paths.)
    #
    # This grant is no longer load-bearing: ./hm1092 now resolves the same LED
    # through int3472's lookup and drives it around streaming itself, in kernel
    # context, so an unmodified consumer gets lit frames without touching sysfs.
    # It is kept because the emitter is otherwise invisible to a user debugging
    # a dark-frames report -- being able to run
    #   echo 1 > /sys/class/leds/HIMX1092_00::ir_flood_led/brightness
    # and see whether the scene lights up separates a sensor problem from an
    # illuminator problem in one step. Measured on a DA14260: 100% near-black
    # pixels unlit versus 0.4% lit.
    #
    # The second rule hands out a stable path for the IR capture node itself.
    # ISYS registers one capture node per CSI-2 stream (~32 on this machine) and
    # /dev/videoN numbering follows registration order, so the IR node's number
    # is not stable across boots and there is nothing safe to write into a
    # face-auth config. Worse, the numeric default such configs usually ship,
    # /dev/video2, is a real but unrelated ISYS node here -- so getting it wrong
    # opens the wrong camera rather than failing to open one.
    #
    # The V4L2 card name is stable, and it names the capture entity rather than
    # the node: the sensor's link into "Intel IPU7 CSI2 2" is IMMUTABLE, that
    # port's first pad is the only ENABLED link out of it, and ISYS allocates
    # capture entities eight per CSI-2 port -- so port 2 is entity 16 by
    # construction, whatever /dev/videoN it happens to get. udev exposes that
    # name as ATTR{name}.
    #
    # Do not switch this to the sensor's i2c name ("hm1092 16-0024"): the 16
    # there is the usbio-tunnelled bus number, which genuinely does vary.
    services.udev.extraRules = ''
      SUBSYSTEM=="leds", KERNEL=="*ir_flood_led*", ACTION=="add|change", RUN+="${pkgs.coreutils}/bin/chgrp video /sys%p/brightness", RUN+="${pkgs.coreutils}/bin/chmod 0664 /sys%p/brightness"
      SUBSYSTEM=="video4linux", ATTR{name}=="Intel IPU7 ISYS Capture 16", SYMLINK+="ir-camera"
    '';
  };
}
