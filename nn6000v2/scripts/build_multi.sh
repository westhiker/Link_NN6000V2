#!/usr/bin/env bash
set -euo pipefail

if [ -d "nn6000v2" ]; then
  NN6000V2_PATH="nn6000v2"
elif [ -d "../nn6000v2" ]; then
  NN6000V2_PATH="../nn6000v2"
else
  echo "Error: nn6000v2 directory not found!"
  exit 1
fi

BASE_PATH="$(cd "$NN6000V2_PATH" && pwd)"
ROOT_PATH="$(cd "$BASE_PATH/.." && pwd)"

REPO_URL="${REPO_URL:-https://github.com/VIKINGYFY/immortalwrt.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
BUILD_DIR="${BUILD_DIR:-action_build}"
COMMIT_HASH="${COMMIT_HASH:-none}"

BUILD_PATH="$ROOT_PATH/$BUILD_DIR"
FIRMWARE_PATH="$ROOT_PATH/firmware"

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <device1> [device2] ..."
  exit 1
fi

DEVICES=("$@")

if [ ! -d "$BUILD_PATH" ]; then
  "$BASE_PATH/scripts/update.sh" "$REPO_URL" "$REPO_BRANCH" "$BUILD_DIR" "$COMMIT_HASH"
fi

remove_uhttpd_dependency() {
  local config_path="$BUILD_PATH/.config"
  local luci_makefile_path="$BUILD_PATH/feeds/luci/collections/luci/Makefile"

  if grep -q "CONFIG_PACKAGE_luci-app-quickfile=y" "$config_path"; then
    if [ -f "$luci_makefile_path" ]; then
      sed -i '/luci-light/d' "$luci_makefile_path"
      echo "Removed uhttpd/luci-light dependency."
    fi
  fi
}

apply_config() {
  local dev="$1"
  local config_file="$BASE_PATH/configs/$dev.config"

  if [ ! -f "$config_file" ]; then
    echo "Config not found: $config_file"
    exit 1
  fi

  cp -f "$config_file" "$BUILD_PATH/.config"

  if [ -f "$BASE_PATH/configs/docker_deps.config" ]; then
    cat "$BASE_PATH/configs/docker_deps.config" >> "$BUILD_PATH/.config"
  fi
}

fix_netfilter_kmod_clash() {
  local include_netfilter_mk="$BUILD_PATH/include/netfilter.mk"
  local netfilter_mk="$BUILD_PATH/package/kernel/linux/modules/netfilter.mk"

  [ -f "$include_netfilter_mk" ] || return 0
  [ -f "$netfilter_mk" ] || return 0

  if grep -q 'CONFIG_IP_NF_IPTABLES_LEGACY, $(P_V4)ip_tables, ge 6.12' "$include_netfilter_mk"; then
    echo "Netfilter workaround already applied."
    return 0
  fi

  sed -i 's@$(eval $(if $(NF_KMOD),$(call nf_add,NF_IPT,CONFIG_IP_NF_IPTABLES, $(P_V4)ip_tables),))@$(eval $(if $(NF_KMOD),$(call nf_add,NF_IPT,CONFIG_IP_NF_IPTABLES, $(P_V4)ip_tables, lt 6.12),))@' "$include_netfilter_mk" || true
  sed -i '/CONFIG_IP_NF_IPTABLES, $(P_V4)ip_tables, lt 6\.12)/a$(eval $(if $(NF_KMOD),$(call nf_add,NF_IPT,CONFIG_IP_NF_IPTABLES_LEGACY, $(P_V4)ip_tables, ge 6.12),))' "$include_netfilter_mk" || true

  sed -i 's@$(eval $(if $(NF_KMOD),,$(call nf_add,IPT_CORE,CONFIG_IP_NF_IPTABLES, xt_standard ipt_icmp xt_tcp xt_udp xt_comment xt_set xt_SET)))@$(eval $(if $(NF_KMOD),,$(call nf_add,IPT_CORE,CONFIG_IP_NF_IPTABLES, xt_standard ipt_icmp xt_tcp xt_udp xt_comment xt_set xt_SET, lt 6.12)))@' "$include_netfilter_mk" || true
  sed -i '/CONFIG_IP_NF_IPTABLES, xt_standard ipt_icmp xt_tcp xt_udp xt_comment xt_set xt_SET, lt 6\.12))/a$(eval $(if $(NF_KMOD),,$(call nf_add,IPT_CORE,CONFIG_IP_NF_IPTABLES_LEGACY, xt_standard ipt_icmp xt_tcp xt_udp xt_comment xt_set xt_SET, ge 6.12)))' "$include_netfilter_mk" || true

  sed -i 's@$(eval $(if $(NF_KMOD),$(call nf_add,NF_IPT6,CONFIG_IP6_NF_IPTABLES, $(P_V6)ip6_tables),))@$(eval $(if $(NF_KMOD),$(call nf_add,NF_IPT6,CONFIG_IP6_NF_IPTABLES, $(P_V6)ip6_tables, lt 6.12),))@' "$include_netfilter_mk" || true
  sed -i '/CONFIG_IP6_NF_IPTABLES, $(P_V6)ip6_tables, lt 6\.12)/a$(eval $(if $(NF_KMOD),$(call nf_add,NF_IPT6,CONFIG_IP6_NF_IPTABLES_LEGACY, $(P_V6)ip6_tables, ge 6.12),))' "$include_netfilter_mk" || true

  sed -i 's@$(eval $(if $(NF_KMOD),,$(call nf_add,IPT_IPV6,CONFIG_IP6_NF_IPTABLES, ip6t_icmp6)))@$(eval $(if $(NF_KMOD),,$(call nf_add,IPT_IPV6,CONFIG_IP6_NF_IPTABLES, ip6t_icmp6, lt 6.12)))@' "$include_netfilter_mk" || true
  sed -i '/CONFIG_IP6_NF_IPTABLES, ip6t_icmp6, lt 6\.12))/a$(eval $(if $(NF_KMOD),,$(call nf_add,IPT_IPV6,CONFIG_IP6_NF_IPTABLES_LEGACY, ip6t_icmp6, ge 6.12)))' "$include_netfilter_mk" || true

  sed -i 's/DEPENDS:=+!LINUX_6_12:kmod-iptables/DEPENDS:=+(!(LINUX_6_12||LINUX_6_18)):kmod-iptables/' "$netfilter_mk" || true

  echo "Netfilter workaround applied."
}

modify_kernel_size() {
  local ipq60xx_mk_path="$BUILD_PATH/target/linux/qualcommax/image/ipq60xx.mk"

  if [ -f "$ipq60xx_mk_path" ]; then
    sed -i '/link_nn6000-common/,/endef/{s/KERNEL_SIZE := 6144k/KERNEL_SIZE := 12288k/g}' "$ipq60xx_mk_path"
    echo "Updated KERNEL_SIZE to 12288k for link_nn6000 devices."
  fi
}

clean_target_output() {
  local target_dir="$BUILD_PATH/bin/targets"

  if [ -d "$target_dir" ]; then
    find "$target_dir" -type f \( \
      -name "*.bin" \
      -o -name "*.manifest" \
      -o -name "*.img.gz" \
      -o -name "*.itb" \
      -o -name "*.fip" \
      -o -name "*.ubi" \
      -o -name "*rootfs.tar.gz" \
    \) -delete
  fi
}

copy_firmware() {
  local dev="$1"
  local out_dir="$FIRMWARE_PATH/$dev"

  mkdir -p "$out_dir"

  find "$BUILD_PATH/bin/targets" -type f \( \
    -name "*.bin" \
    -o -name "*.manifest" \
    -o -name "*.img.gz" \
    -o -name "*.itb" \
    -o -name "*.fip" \
    -o -name "*.ubi" \
    -o -name "*rootfs.tar.gz" \
  \) -exec cp -f {} "$out_dir/" \;

  echo "Firmware for $dev:"
  ls -lh "$out_dir" || true
}

build_first_device() {
  local dev="$1"

  echo "=============================================="
  echo "Full build: $dev"
  echo "=============================================="

  apply_config "$dev"
  fix_netfilter_kmod_clash
  remove_uhttpd_dependency
  modify_kernel_size

  cd "$BUILD_PATH"
  make defconfig

  clean_target_output

  make download -j"$(($(nproc) * 2))"
  make -j"$(($(nproc) + 1))" || make -j1 V=s

  copy_firmware "$dev"
}

build_next_device_image_only() {
  local dev="$1"

  echo "=============================================="
  echo "Image-only build: $dev"
  echo "=============================================="

  apply_config "$dev"
  fix_netfilter_kmod_clash
  remove_uhttpd_dependency
  modify_kernel_size

  cd "$BUILD_PATH"
  make defconfig

  clean_target_output

  make target/linux/clean
  make target/linux/compile -j"$(($(nproc) + 1))" || make target/linux/compile V=s
  make target/install -j"$(($(nproc) + 1))" || make target/install V=s

  copy_firmware "$dev"
}

rm -rf "$FIRMWARE_PATH"
mkdir -p "$FIRMWARE_PATH"

FIRST=1

for DEV in "${DEVICES[@]}"; do
  if [ "$FIRST" = "1" ]; then
    build_first_device "$DEV"
    FIRST=0
  else
    build_next_device_image_only "$DEV"
  fi
done

echo "All devices finished."
find "$FIRMWARE_PATH" -maxdepth 2 -type f -print
