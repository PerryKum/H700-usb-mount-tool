#!/bin/bash

if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash --noprofile --norc "$0" "$@"
  fi
  for _B in /bin/bash /usr/bin/bash; do
    [ -x "${_B}" ] && exec "${_B}" --noprofile --norc "$0" "$@"
  done
  exit 127
fi

set +e
set +o pipefail 2>/dev/null || true

# 启动器拉起 APPS 时 PATH 可能偏窄，补上常见路径
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"
export PATH

readonly GADGET_NAME="${GADGET_NAME:-anbernic_msd_usb}"
readonly GADGET_ROOT="/sys/kernel/config/usb_gadget/${GADGET_NAME}"
readonly KERNEL_STATE_DIR="/run/usb_gadget_${GADGET_NAME}"
readonly SESSION="/run/usb_msd_auto"

# 图在脚本同目录 res/USB_EXIT_hint.png；卸卡前拷到 tmpfs，由 mpv 全屏显示。
cache_usb_hint_png() {
  local dest="$SESSION/USB_EXIT_hint.png" pack hint
  mkdir -p "$SESSION" 2>/dev/null || true
  pack=""
  [ -f "$SESSION/pack_dir.txt" ] && pack="$(cat "$SESSION/pack_dir.txt" 2>/dev/null)"
  hint="${pack}/res/USB_EXIT_hint.png"
  if [ -n "$pack" ] && [ -f "$hint" ] && cp -f "$hint" "$dest" 2>/dev/null; then
    return 0
  fi
  rm -f "$dest" 2>/dev/null || true
  return 0
}

# 与「启动LOGO管理器.sh」一致：mpv 全屏播图。
pick_mpv() {
  local pack="${1-}" p
  if [ -n "$pack" ]; then
    for p in "${pack}/res/mpv" "${pack}/mpv"; do
      [ -x "$p" ] && {
        echo "$p"
        return 0
      }
    done
  fi
  [ -x /usr/bin/mpv ] && {
    echo /usr/bin/mpv
    return 0
  }
  if command -v mpv >/dev/null 2>&1; then
    command -v mpv
    return 0
  fi
  return 1
}

# 与 启动LOGO管理器.sh 第 33–37 行一致：rotate_28 要么是「空格+旋转参数+空格」，要么是单个空格。
_hint_mpv_rotate_word() {
  local m
  [ -f /mnt/vendor/oem/board.ini ] || {
    echo " "
    return 0
  }
  m="$(head -n 1 /mnt/vendor/oem/board.ini 2>/dev/null)"
  if [[ "$m" == "RG28xx" ]] && [[ "$(cat /sys/class/extcon/hdmi/state 2>/dev/null)" == "HDMI=0" ]]; then
    echo " --video-rotate=270 --no-sub "
  else
    echo " "
  fi
}

hint_mpv_fullscreen_png() {
  local img="$1" pack="$2" mpv_bin rot pid
  mpv_bin="$(pick_mpv "$pack")" || {
    return 1
  }
  rot="$(_hint_mpv_rotate_word)"

  # 启动LOGO管理器.sh 第 149–151 行：先 pkill mpv/evtest，再起 mpv。
  # 关键：不用 setsid、不把 stdin/stdout 接到 /dev/null（与示例一致，否则易出现「进程在但无画面」）。
  pkill -f mpv 2>/dev/null || true
  pkill -f evtest 2>/dev/null || true

  # 与示例同一组参数：$rotate_28 --really-quiet --fs --image-display-duration=6000 file &
  # 时长用 864000 约 10 天，避免 USB 会话中途 mpv 自己退出；若需与示例逐字相同可改回 6000。
  "$mpv_bin" $rot --really-quiet --fs --image-display-duration=864000 "$img" &
  pid=$!
  sleep 0.35
  if kill -0 "$pid" 2>/dev/null; then
    echo "$pid" >"$SESSION/hint_mpv.pid" 2>/dev/null || true
    return 0
  fi
  wait "$pid" 2>/dev/null
  return 1
}

show_usb_hint_on_fb() {
  local img="$SESSION/USB_EXIT_hint.png" pack
  pack=""
  [ -f "$SESSION/pack_dir.txt" ] && pack="$(cat "$SESSION/pack_dir.txt" 2>/dev/null)"
  [ -r "$img" ] || return 0
  hint_mpv_fullscreen_png "$img" "$pack" || true
  return 0
}

kill_usb_hint_viewer() {
  if [ -f "$SESSION/hint_mpv.pid" ]; then
    kill "$(cat "$SESSION/hint_mpv.pid" 2>/dev/null)" 2>/dev/null || true
    rm -f "$SESSION/hint_mpv.pid" 2>/dev/null || true
  fi
}

need_root() {
  if [ "$(id -u 2>/dev/null)" != "0" ]; then
    sleep 8
    exit 1
  fi
}

ensure_configfs() {
  if [ -d /sys/kernel/config/usb_gadget ]; then
    return 0
  fi
  modprobe libcomposite 2>/dev/null || true
  mount -t configfs none /sys/kernel/config 2>/dev/null || true
  mount -t configfs configfs /sys/kernel/config 2>/dev/null || true
  [ -d /sys/kernel/config/usb_gadget ] && return 0
  return 1
}

find_udc() {
  local u
  [ -d /sys/class/udc ] || return 1
  for u in /sys/class/udc/*; do
    [ -e "$u" ] || continue
    basename "$u"
    return 0
  done
  return 1
}

gadget_off() {
  if [ ! -d "$GADGET_ROOT" ]; then
    return 0
  fi
  if [ -f "$KERNEL_STATE_DIR/udc" ]; then
    local udc
    udc="$(cat "$KERNEL_STATE_DIR/udc" 2>/dev/null)"
    if [ -n "$udc" ] && [ -f "$GADGET_ROOT/UDC" ]; then
      printf '' >"$GADGET_ROOT/UDC" 2>/dev/null || true
    fi
  fi
  if [ -d "$GADGET_ROOT/configs" ]; then
    find "$GADGET_ROOT/configs" -mindepth 2 -maxdepth 2 -type l 2>/dev/null | while read -r L; do
      rm -f "$L" 2>/dev/null || true
    done
  fi
  if [ -d "$GADGET_ROOT/functions" ]; then
    local fn
    for fn in "$GADGET_ROOT/functions"/*; do
      [ -e "$fn" ] || continue
      [ -d "$fn/lun.0" ] && printf '' >"$fn/lun.0/file" 2>/dev/null || true
      rm -rf "$fn" 2>/dev/null || true
    done
  fi
  rm -rf "$GADGET_ROOT" "$KERNEL_STATE_DIR" 2>/dev/null || true
  sync 2>/dev/null || true
  sync 2>/dev/null || true
}

on_shell_exit() {
  gadget_off 2>/dev/null || true
  sync 2>/dev/null || true
}
trap on_shell_exit EXIT

gadget_on() {
  local backing="$1" udc

  if ! ensure_configfs; then
    return 1
  fi

  [ -e "$backing" ] || {
    return 1
  }
  if [ -d "$GADGET_ROOT" ]; then
    gadget_off || true
  fi
  command -v find >/dev/null 2>&1 || {
    return 1
  }

  udc="$(find_udc)" || {
    return 1
  }

  mkdir -p "$KERNEL_STATE_DIR" || true
  printf '%s' "$udc" >"$KERNEL_STATE_DIR/udc" || {
    return 1
  }
  mkdir -p "$GADGET_ROOT" || {
    return 1
  }

  (
    set -e
    cd "$GADGET_ROOT" || exit 1
    printf '0x1d6b\n' >idVendor
    printf '0x0104\n' >idProduct
    printf '0x0100\n' >bcdDevice
    printf '0x0200\n' >bcdUSB
    mkdir -p strings/0x409
    printf 'ANBERNIC\n' >strings/0x409/manufacturer
    printf 'MSD\n' >strings/0x409/product
    printf '1\n' >strings/0x409/serialnumber
    mkdir -p configs/c.1/strings/0x409
    printf 'cfg\n' >configs/c.1/strings/0x409/configuration
    printf '250\n' >configs/c.1/MaxPower
    mkdir -p functions/mass_storage.0
    [ -w functions/mass_storage.0/lun.0/ro ] && printf '0\n' >functions/mass_storage.0/lun.0/ro 2>/dev/null || true
    printf '%s\n' "$backing" >functions/mass_storage.0/lun.0/file
    ln -s functions/mass_storage.0 configs/c.1/
    printf '%s\n' "$udc" >UDC
  )
  if [ "$?" != "0" ]; then
    gadget_off 2>/dev/null || true
    return 1
  fi
  sync 2>/dev/null || true
  return 0
}

auto_pick_backing() {
  # 注意：本函数 stdout 只能输出「一行块设备路径」，供 backing="$(auto_pick_backing)" 捕获。
  # 其它说明一律走 stderr，否则会拼进 backing 导致 gadget_on 报「路径不存在」。
  cd / 2>/dev/null || true

  if [ -b /dev/mmcblk1 ]; then
    umount -lf /mnt/sdcard 2>/dev/null || true
    for p in /dev/mmcblk1p*; do
      [ -b "$p" ] || continue
      umount -lf "$p" 2>/dev/null || true
    done
    echo /dev/mmcblk1
    return 0
  fi

  local mp src
  for mp in /mnt/mmc /mnt/sdcard /media/mmc /media/sdcard /run/media/mmc; do
    [ -d "$mp" ] || continue
    src="$(findmnt -nr -o SOURCE --target "$mp" 2>/dev/null || true)"
    if [ -n "$src" ] && [ -b "$src" ]; then
      umount -lf "$mp" 2>/dev/null || true
      echo "$src"
      return 0
    fi
  done

  return 1
}

write_off_helper() {
  mkdir -p "$SESSION" || true
  cat >"$SESSION/off.sh" <<EOF
#!/bin/bash
set +e
[ -f /run/usb_msd_auto/hint_mpv.pid ] && kill "$(cat /run/usb_msd_auto/hint_mpv.pid)" 2>/dev/null || true
rm -f /run/usb_msd_auto/hint_mpv.pid 2>/dev/null || true
GADGET_ROOT="${GADGET_ROOT}"
KERNEL_STATE_DIR="${KERNEL_STATE_DIR}"
if [ ! -d "\$GADGET_ROOT" ]; then exit 0; fi
if [ -f "\$KERNEL_STATE_DIR/udc" ] && [ -f "\$GADGET_ROOT/UDC" ]; then
  printf '' >"\$GADGET_ROOT/UDC" 2>/dev/null || true
fi
if [ -d "\$GADGET_ROOT/configs" ]; then
  find "\$GADGET_ROOT/configs" -mindepth 2 -maxdepth 2 -type l 2>/dev/null | while read -r L; do rm -f "\$L" 2>/dev/null || true; done
fi
if [ -d "\$GADGET_ROOT/functions" ]; then
  for fn in "\$GADGET_ROOT/functions"/*; do
    [ -e "\$fn" ] || continue
    [ -d "\$fn/lun.0" ] && printf '' >"\$fn/lun.0/file" 2>/dev/null || true
    rm -rf "\$fn" 2>/dev/null || true
  done
fi
rm -rf "\$GADGET_ROOT" "\$KERNEL_STATE_DIR" 2>/dev/null || true
sync 2>/dev/null || true
sync 2>/dev/null || true
EOF
  chmod 755 "$SESSION/off.sh" 2>/dev/null || true
}

run_input_monitor() {
  if ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi

  python3 -u - <<'PY'
# 不用 selectors：部分固件 epoll/大量 fd 会崩；改用 select + 限制 event 数量
import glob, os, select, struct, subprocess, time

EV_KEY = 1
BTN_EAST = 305
BTN_SELECT = 310
BTN_START = 311
MAX_FD = 24

def pick_fds():
    paths = sorted(glob.glob("/dev/input/event*"))[:MAX_FD]
    out = []
    for path in paths:
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            out.append(fd)
        except OSError:
            pass
    return out

def process_chunk(data, pressed, off_sh):
    for i in range(0, len(data), 24):
        chunk = data[i : i + 24]
        if len(chunk) < 24:
            break
        try:
            _a, _b, ev_type, code, value = struct.unpack("@llHHi", chunk)
        except struct.error:
            continue
        if ev_type != EV_KEY:
            continue
        if value == 1:
            pressed.add(code)
        elif value == 0:
            pressed.discard(code)
        if code == BTN_EAST and value == 1:
            subprocess.check_call(["/bin/bash", off_sh])
            return True
        if BTN_SELECT in pressed and BTN_START in pressed:
            subprocess.check_call(["/bin/bash", off_sh])
            return True
    return False

def main():
    off_sh = "/run/usb_msd_auto/off.sh"
    pressed = set()
    fds = pick_fds()
    if not fds:
        return
    while True:
        try:
            r, _, _ = select.select(fds, [], [], 3600)
        except InterruptedError:
            continue
        except ValueError:
            time.sleep(2)
            continue
        for fd in r:
            try:
                data = os.read(fd, 4096)
            except BlockingIOError:
                continue
            except OSError:
                continue
            if process_chunk(data, pressed, off_sh):
                return

if __name__ == "__main__":
    try:
        main()
    except Exception:
        try:
            subprocess.check_call(["/bin/bash", "/run/usb_msd_auto/off.sh"])
        except Exception:
            pass
        raise
PY
  _py="$?"
  if [ "$_py" != "0" ]; then
    bash "$SESSION/off.sh" 2>/dev/null || true
  fi
}

# 若脚本在「即将被导出并 umount 的 TF」上（例如 /mnt/sdcard/...），
# umount 后 bash 无法再读脚本 → loading 一会后直接退出。必须先复制到 tmpfs 再 exec。
stage_self_to_run() {
  case "${0}" in
    /run/usb_msd_exec.sh) return 0 ;;
  esac
  local src="${BASH_SOURCE[0]:-$0}"
  case "$src" in
    /run/usb_msd_exec.sh) return 0 ;;
  esac

  mkdir -p /run "$SESSION" 2>/dev/null || true
  case "$src" in */*)
    { cd "${src%/*}" 2>/dev/null && pwd >"$SESSION/pack_dir.txt"; } || rm -f "$SESSION/pack_dir.txt"
    ;;
  *)
    pwd >"$SESSION/pack_dir.txt" 2>/dev/null || rm -f "$SESSION/pack_dir.txt"
    ;;
  esac
  if ! cp -f "$src" /run/usb_msd_exec.sh 2>/dev/null; then
    if ! cat "$src" >/run/usb_msd_exec.sh 2>/dev/null; then
      return 1
    fi
  fi
  chmod 755 /run/usb_msd_exec.sh 2>/dev/null || true
  sync 2>/dev/null || true
  exec /bin/bash --noprofile --norc /run/usb_msd_exec.sh
}

main() {
  stage_self_to_run || {
    sleep 5
    exit 1
  }
  cd / 2>/dev/null || cd /run 2>/dev/null || true
  need_root
  mkdir -p "$SESSION" || true

  if [ ! -d /sys/class/udc ]; then
    sleep 8
    exit 1
  fi
  if ! ls /sys/class/udc/* >/dev/null 2>&1; then
    sleep 8
    exit 1
  fi

  cache_usb_hint_png

  backing=""
  backing="$(auto_pick_backing)" || true
  if [ -z "$backing" ]; then
    sleep 8
    exit 1
  fi

  if ! gadget_on "$backing"; then
    sleep 8
    exit 1
  fi

  write_off_helper
  show_usb_hint_on_fb
  run_input_monitor
  kill_usb_hint_viewer
  exit 0
}

main "$@"
