#!/bin/bash
# GPU のハードウェアエンコード対応を調べる
#   vaapi : vainfo のプロファイル一覧と、ffmpeg で実際に試したコーデック × low_power × レート制御の対応表
#   qsv   : Intel GPU の QSV で、コーデック × レート制御の対応表
#   nvenc : NVIDIA GPU の NVENC で、コーデック × レート制御と、B フレーム・AQ などの機能の対応表
#
# 使い方: hwenc-check [-r|--recommend] [vaapi|qsv|nvenc|intel|all ...]
#   intel は vaapi qsv と同じ。省略すると、見えている GPU に合わせて自動で選ぶ
#   (/dev/dri があれば vaapi と qsv、NVIDIA GPU があれば nvenc)
#   -r / --recommend を付けると、結果から選んだおすすめのエンコード設定を最後に出す
#
# 環境変数:
#   TARGET             引数の代わりに調べる対象を指定する (例: TARGET="qsv nvenc")
#   VAAPI_DEVICE       調べるレンダーノード (未指定なら /dev/dri/renderD* を全部調べる)
#   LIBVA_DRIVER_NAME  VA-API ドライバ (未指定なら GPU のベンダーから選ぶ。Intel は iHD → i965 の順に試す)
#   NVENC_GPU          調べる NVIDIA GPU の番号 (未指定なら全部調べる)
#   SIZE               テスト映像の解像度 (既定 1920x1080)
#   RECOMMEND          1 にすると --recommend と同じ (既定 0)
#   REC_HEVC_Q         おすすめ設定で使う HEVC の品質値 (既定 22。NVENC の cq は +1)
#   REC_H264_Q         おすすめ設定で使う H.264 の品質値 (既定 20。NVENC の cq は +1)
set -uo pipefail

SIZE="${SIZE:-1920x1080}"
USER_DRIVER="${LIBVA_DRIVER_NAME:-}"
VAINFO_OUT="$(mktemp)"
trap 'rm -f "$VAINFO_OUT"' EXIT

usage() { sed -n '7,10p' "$0" | sed 's/^# \{0,1\}//'; }

# ---- 調べる対象を決める ----
WANT_VAAPI=0 WANT_QSV=0 WANT_NVENC=0
RECOMMEND="${RECOMMEND:-0}"
REQ=()
for a in "$@"; do
  case "$a" in
    -r|--recommend) RECOMMEND=1 ;;
    --no-recommend) RECOMMEND=0 ;;
    *) REQ+=("$a") ;;
  esac
done
[ ${#REQ[@]} -eq 0 ] && read -r -a REQ <<<"${TARGET:-}"
for t in "${REQ[@]}"; do
  case "$t" in
    vaapi) WANT_VAAPI=1 ;;
    qsv)   WANT_QSV=1 ;;
    nvenc) WANT_NVENC=1 ;;
    intel) WANT_VAAPI=1 WANT_QSV=1 ;;
    all)   WANT_VAAPI=1 WANT_QSV=1 WANT_NVENC=1 ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "unknown target: $t" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -n "${VAAPI_DEVICE:-}" ]; then
  DEVICES=("$VAAPI_DEVICE")
else
  DEVICES=(/dev/dri/renderD*)
fi
HAVE_DRI=0
[ -e "${DEVICES[0]}" ] && HAVE_DRI=1

# NVIDIA GPU の番号を集める (NVIDIA Container Toolkit が nvidia-smi とドライバのライブラリを入れてくれる)
NV_GPUS=()
if command -v nvidia-smi >/dev/null 2>&1; then
  mapfile -t NV_GPUS < <(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null)
elif ldconfig -p 2>/dev/null | grep libnvidia-encode >/dev/null; then
  NV_GPUS=(0)
fi
[ -n "${NVENC_GPU:-}" ] && NV_GPUS=("$NVENC_GPU")

if [ ${#REQ[@]} -eq 0 ]; then
  [ "$HAVE_DRI" = 1 ] && WANT_VAAPI=1 WANT_QSV=1
  [ ${#NV_GPUS[@]} -gt 0 ] && WANT_NVENC=1
  if [ "$WANT_VAAPI$WANT_NVENC" = 00 ]; then
    echo "GPU が見えない。Intel / AMD は --device /dev/dri、NVIDIA は --gpus all を docker run に付ける" >&2
    exit 1
  fi
fi
if [ "$WANT_VAAPI$WANT_QSV" != 00 ] && [ "$HAVE_DRI" = 0 ]; then
  echo "レンダーノードが見つからない。docker run に --device /dev/dri を付ける" >&2
  exit 1
fi
if [ "$WANT_NVENC" = 1 ] && [ ${#NV_GPUS[@]} -eq 0 ]; then
  echo "NVIDIA GPU が見えない。ホストに NVIDIA Container Toolkit を入れ、docker run に --gpus all を付ける" >&2
  exit 1
fi

ENCODERS="$(ffmpeg -hide_banner -encoders 2>/dev/null)"
has_encoder() { grep -qw "$1" <<<"$ENCODERS"; }

# テスト結果。RES["<va|qsv|nv>|<デバイス>|<コーデック>|...|<列>"]=OK/NG
declare -A RES
declare -A DRV_OF     # レンダーノードごとに使った VA-API ドライバ
declare -A KDRV_OF    # レンダーノードごとのカーネルドライバ (i915 / xe など)
VA_DONE=() QSV_DONE=() NV_DONE=()

# ---- 表の出力 ----
COLS=(CQP CBR VBR ICQ QVBR AVBR)
QSV_COLS=(CQP ICQ VBR CBR)
row() { printf '%-12s' "$1"; shift; printf ' %-9s' "$1"; shift; printf ' %-5s' "$@"; echo; }

# ---- VA-API ----
declare -A ENT        # ENT["<プロファイル> <エントリポイント>"]=1
PROFILES=()

has_ent() {   # has_ent <エントリポイント> <プロファイル...>
  local e="$1" p; shift
  for p in "$@"; do [ -n "${ENT["$p $e"]:-}" ] && return 0; done
  return 1
}

va_try() {   # va_try <エンコーダ> <pix_fmt> [オプション...]
  local enc="$1" fmt="$2"; shift 2
  ffmpeg -hide_banner -nostdin -v error \
    -init_hw_device "vaapi=va:$DEV" -filter_hw_device va \
    -f lavfi -i "testsrc2=size=$SIZE:rate=30" -frames:v 10 \
    -vf "${VA_VF:-format=$fmt,hwupload}" -c:v "$enc" "$@" -f null - >/dev/null 2>&1
}

va_rc_opts() {   # レート制御ごとのオプション
  case "$1" in
    CQP)  echo "-rc_mode CQP -qp 26" ;;
    CBR)  echo "-rc_mode CBR -b:v 6M" ;;
    VBR)  echo "-rc_mode VBR -b:v 6M -maxrate 9M" ;;
    ICQ)  echo "-rc_mode ICQ -global_quality 26" ;;
    QVBR) echo "-rc_mode QVBR -global_quality 26 -b:v 6M -maxrate 9M" ;;
    AVBR) echo "-rc_mode AVBR -b:v 6M" ;;
  esac
}

# 表示名 | ffmpeg エンコーダ | pix_fmt | 対応する vainfo のプロファイル | 追加オプション
VA_ROWS=(
  "H.264|h264_vaapi|nv12|VAProfileH264High VAProfileH264Main VAProfileH264ConstrainedBaseline|"
  "HEVC|hevc_vaapi|nv12|VAProfileHEVCMain|"
  "HEVC-10bit|hevc_vaapi|p010|VAProfileHEVCMain10|-profile:v main10"
  "AV1|av1_vaapi|nv12|VAProfileAV1Profile0|"
  "AV1-10bit|av1_vaapi|p010|VAProfileAV1Profile0|"
  "VP9|vp9_vaapi|nv12|VAProfileVP9Profile0|"
  "VP9-10bit|vp9_vaapi|p010|VAProfileVP9Profile2|-profile:v 2"
  "VP8|vp8_vaapi|nv12|VAProfileVP8Version0_3|"
  "MPEG-2|mpeg2_vaapi|nv12|VAProfileMPEG2Main VAProfileMPEG2Simple|"
)

va_check() {
  local name enc fmt profs extra lp rc cells lp_opts
  echo "-- VA-API エンコード (ffmpeg で実際に試した結果)"
  row codec low_power "${COLS[@]}"
  for r in "${VA_ROWS[@]}"; do
    IFS='|' read -r name enc fmt profs extra <<<"$r"
    # shellcheck disable=SC2206
    local prof_arr=($profs) extra_arr=($extra)
    if ! has_encoder "$enc"; then
      row "$name" "-" "(この ffmpeg には $enc が無い)"
      continue
    fi
    if ! has_ent VAEntrypointEncSlice "${prof_arr[@]}" && ! has_ent VAEntrypointEncSliceLP "${prof_arr[@]}"; then
      row "$name" "-" "(エンコード非対応)"
      continue
    fi
    # おすすめ設定で経路を判断するため、使えるエントリポイントを覚えておく
    has_ent VAEntrypointEncSlice "${prof_arr[@]}" && RES["va|$DEV|$name|has0"]=1
    has_ent VAEntrypointEncSliceLP "${prof_arr[@]}" && RES["va|$DEV|$name|has1"]=1
    for lp in auto 0 1; do
      case "$lp" in
        auto) lp_opts=() ;;
        *)    lp_opts=(-low_power "$lp") ;;
      esac
      cells=()
      for rc in "${COLS[@]}"; do
        if ! case "$lp" in
               auto) has_ent VAEntrypointEncSlice "${prof_arr[@]}" || has_ent VAEntrypointEncSliceLP "${prof_arr[@]}" ;;
               0)    has_ent VAEntrypointEncSlice "${prof_arr[@]}" ;;
               1)    has_ent VAEntrypointEncSliceLP "${prof_arr[@]}" ;;
             esac; then
          cells+=("-")
        else
          # shellcheck disable=SC2046
          if va_try "$enc" "$fmt" "${lp_opts[@]}" $(va_rc_opts "$rc") "${extra_arr[@]}"; then
            cells+=(OK)
          else
            cells+=(NG)
          fi
          RES["va|$DEV|$name|$lp|$rc"]="${cells[-1]}"
        fi
      done
      row "$name" "$lp" "${cells[@]}"
    done
  done
  # JPEG はレート制御が無いので、エンコードできるかだけ見る
  if has_encoder mjpeg_vaapi; then
    if ! has_ent VAEntrypointEncPicture VAProfileJPEGBaseline; then
      row JPEG auto "-"
    elif va_try mjpeg_vaapi nv12 -global_quality 80; then
      row JPEG auto "OK (品質指定のみ)"
    else
      row JPEG auto "NG"
    fi
  fi
  echo
}

# ---- QSV ----
qsv_rc_opts() {
  case "$1" in
    CQP) echo "-q:v 26" ;;
    ICQ) echo "-global_quality 26" ;;
    VBR) echo "-b:v 6M -maxrate 9M" ;;
    CBR) echo "-b:v 6M -maxrate 6M" ;;
  esac
}

# 成功して、ログに出たレート制御が狙いどおりなら OK。違う方式で動いたら OK* にする
qsv_cell() {   # qsv_cell <エンコーダ> <pix_fmt> <レート制御> [追加オプション...]
  local enc="$1" fmt="$2" rc="$3" log; shift 3
  # shellcheck disable=SC2046
  if log=$(ffmpeg -hide_banner -nostdin -v verbose \
             -init_hw_device "qsv=qs:hw,child_device=$DEV" -filter_hw_device qs \
             -f lavfi -i "testsrc2=size=$SIZE:rate=30" -frames:v 10 \
             -vf "format=$fmt" -c:v "$enc" $(qsv_rc_opts "$rc") "$@" -f null - 2>&1); then
    if grep -i ratecontrol <<<"$log" | grep -w "$rc" >/dev/null; then echo OK; else echo 'OK*'; fi
  else
    echo NG
  fi
}

QSV_ROWS=(
  "H.264|h264_qsv|nv12|"
  "HEVC|hevc_qsv|nv12|"
  "HEVC-10bit|hevc_qsv|p010|-profile:v main10"
  "AV1|av1_qsv|nv12|"
  "AV1-10bit|av1_qsv|p010|"
  "VP9|vp9_qsv|nv12|"
  "MPEG-2|mpeg2_qsv|nv12|"
)

qsv_check() {
  local name enc fmt extra rc cells
  echo "-- QSV エンコード (ffmpeg で実際に試した結果)"
  local rt=() libs
  libs="$(ldconfig -p 2>/dev/null)"   # grep -q でパイプを途中で閉じると pipefail で失敗扱いになるので、先に読み込む
  grep -q 'libmfx-gen\.so' <<<"$libs" && rt+=("oneVPL (libmfx-gen、Tiger Lake 以降)")
  grep -q 'libmfxhw64\.so' <<<"$libs" && rt+=("Media SDK (libmfxhw64、Ice Lake 以前)")
  if [ ${#rt[@]} -eq 2 ]; then
    echo "ランタイム: ${rt[0]} / ${rt[1]}"
  else
    echo "ランタイム: ${rt[0]:-見つからない}"
  fi
  row codec "" "${QSV_COLS[@]}"
  local any_ok=0
  for r in "${QSV_ROWS[@]}"; do
    IFS='|' read -r name enc fmt extra <<<"$r"
    # shellcheck disable=SC2206
    local extra_arr=($extra)
    if ! has_encoder "$enc"; then
      row "$name" "" "(この ffmpeg には $enc が無い)"
      continue
    fi
    cells=()
    for rc in "${QSV_COLS[@]}"; do
      cells+=("$(qsv_cell "$enc" "$fmt" "$rc" "${extra_arr[@]}")")
      RES["qsv|$DEV|$name|$rc"]="${cells[-1]}"
      [ "${cells[-1]}" != NG ] && any_ok=1
    done
    row "$name" "" "${cells[@]}"
  done
  if [ "$any_ok" = 0 ]; then
    if grep -q 'libmfxhw64\.so' <<<"$libs"; then
      echo "QSV が全部 NG: ランタイムはあるが、この GPU では開けなかった (VA-API のドライバも確認する)"
    else
      echo "QSV が全部 NG: Ice Lake 以前の GPU は Media SDK (libmfx1) が必要。LIBMFX1=1 でビルドしたイメージを使う"
    fi
  fi
  echo
}


# ---- NVENC ----
nv_try() {   # nv_try <エンコーダ> <pix_fmt> <GPU 番号> [オプション...]
  local enc="$1" fmt="$2" gpu="$3"; shift 3
  ffmpeg -hide_banner -nostdin -v error \
    -f lavfi -i "testsrc2=size=$SIZE:rate=30" -frames:v 10 \
    -vf "${NV_VF:-format=$fmt}" -c:v "$enc" -gpu "$gpu" "$@" -f null - >/dev/null 2>&1
}

# B フレームの有無で結果が変わらないよう、レート制御と機能のテストは -bf 0 を基本にする
NV_COLS=(CQP CQ VBR CBR)
nv_rc_opts() {
  case "$1" in
    CQP) echo "-rc constqp -qp 26 -bf 0" ;;
    CQ)  echo "-rc vbr -cq 26 -b:v 0 -bf 0" ;;
    VBR) echo "-rc vbr -b:v 6M -maxrate 9M -bf 0" ;;
    CBR) echo "-rc cbr -b:v 6M -bf 0" ;;
  esac
}
NV_FEAT_COLS=(Bframe BrefMid Lookahead SpatialAQ TemporalAQ Multipass)
nv_feat_opts() {
  local base="-rc vbr -cq 26 -b:v 0"
  case "$1" in
    Bframe)     echo "$base -bf 3" ;;
    BrefMid)    echo "$base -bf 3 -b_ref_mode middle" ;;
    Lookahead)  echo "$base -bf 0 -rc-lookahead 20" ;;
    SpatialAQ)  echo "$base -bf 0 -spatial_aq 1" ;;
    TemporalAQ) echo "$base -bf 0 -rc-lookahead 20 -temporal_aq 1" ;;
    Multipass)  echo "$base -bf 0 -multipass qres" ;;
  esac
}

NV_ROWS=(
  "H.264|h264_nvenc|nv12|"
  "HEVC|hevc_nvenc|nv12|"
  "HEVC-10bit|hevc_nvenc|p010le|-profile:v main10"
  "AV1|av1_nvenc|nv12|"
  "AV1-10bit|av1_nvenc|p010le|"
)

nv_table() {   # nv_table <GPU 番号> <rc|feat>
  local gpu="$1" kind="$2" name enc fmt extra c cells cols
  if [ "$kind" = rc ]; then cols=("${NV_COLS[@]}"); else cols=("${NV_FEAT_COLS[@]}"); fi
  printf '%-12s' codec; printf ' %-10s' "${cols[@]}"; echo
  for r in "${NV_ROWS[@]}"; do
    IFS='|' read -r name enc fmt extra <<<"$r"
    # shellcheck disable=SC2206
    local extra_arr=($extra)
    if ! has_encoder "$enc"; then
      printf '%-12s %s\n' "$name" "(この ffmpeg には $enc が無い)"
      continue
    fi
    # 一番基本の設定で通らなければ、そのコーデックは非対応として 1 行にまとめる
    # shellcheck disable=SC2046
    if ! nv_try "$enc" "$fmt" "$gpu" $(nv_rc_opts CQ) "${extra_arr[@]}"; then
      printf '%-12s %s\n' "$name" "(エンコード非対応)"
      continue
    fi
    cells=()
    for c in "${cols[@]}"; do
      # shellcheck disable=SC2046
      if [ "$kind" = rc ]; then
        nv_try "$enc" "$fmt" "$gpu" $(nv_rc_opts "$c") "${extra_arr[@]}" && cells+=(OK) || cells+=(NG)
      else
        nv_try "$enc" "$fmt" "$gpu" $(nv_feat_opts "$c") "${extra_arr[@]}" && cells+=(OK) || cells+=(NG)
      fi
      RES["nv|$gpu|$name|$c"]="${cells[-1]}"
    done
    printf '%-12s' "$name"; printf ' %-10s' "${cells[@]}"; echo
  done
  echo
}

check_nvenc() {
  local gpu info
  for gpu in "${NV_GPUS[@]}"; do
    info="$(nvidia-smi --id="$gpu" --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null)"
    echo "==== NVIDIA GPU $gpu"
    echo "GPU : ${info:-不明} (名前, ドライバ)"
    echo
    echo "-- NVENC レート制御 (ffmpeg で実際に試した結果)"
    nv_table "$gpu" rc
    echo "-- NVENC 機能 (-rc vbr -cq 26 に足して試した結果)"
    nv_table "$gpu" feat
    NV_DONE+=("$gpu")
  done
}

# ---- Intel / AMD (/dev/dri) ----
# Intel GPU の世代と QSV のバージョンを、PCI のデバイス ID から推定する
intel_gen() {   # intel_gen <デバイス ID (0x....)>
  case "${1,,}" in
    0x010?|0x011?|0x012?)       echo "Gen6 / QSV 1 (Sandy Bridge)" ;;
    0x015?|0x016?)              echo "Gen7 / QSV 2 (Ivy Bridge)" ;;
    0x04??|0x0a??|0x0c??|0x0d??) echo "Gen7.5 / QSV 3 (Haswell)" ;;
    0x16??|0x22b?)              echo "Gen8 / QSV 4 (Broadwell)" ;;
    0x19??|0x5a8?)              echo "Gen9 / QSV 5 (Skylake)" ;;
    0x59??|0x3e??|0x9b??|0x87c?|0x318?) echo "Gen9.5 / QSV 6 (Kaby Lake・Coffee Lake・Comet Lake)" ;;
    0x8a??|0x4e??|0x457?)       echo "Gen11 / QSV 7 (Ice Lake)" ;;
    0x9a??|0x4c8?|0x46??|0xa7??|0x490?) echo "Gen12 / QSV 8 (Tiger Lake〜Raptor Lake)" ;;
    0x56??|0x7d??)              echo "Xe-HPG / Xe-LPG / QSV 9 (Arc Alchemist・Meteor Lake・Arrow Lake)" ;;
    0x64??|0xe2??)              echo "Xe2 / QSV 10 (Lunar Lake・Arc Battlemage)" ;;
    *)                          echo "不明 (この一覧に無いデバイス ID)" ;;
  esac
}

# HuC ファームウェアを読み込む設定かどうか (カーネルドライバのパラメータから)
#   低電力の経路 (VDEnc) で CQP 以外のレート制御を使うには HuC が要る
#   ここで分かるのは設定だけで、実際に読み込めたかは測定の結果から判断する
huc_conf() {   # huc_conf <カーネルドライバ>
  local v
  case "$1" in
    xe) echo "xe ドライバ (HuC は自動で読み込まれる)" ;;
    i915)
      v="$(cat /sys/module/i915/parameters/enable_guc 2>/dev/null)"
      case "$v" in
        -1) echo "enable_guc=-1 (自動。読み込むかどうかは世代とカーネルによる)" ;;
        0)  echo "enable_guc=0 (読み込まない)" ;;
        1)  echo "enable_guc=1 (GuC だけ。HuC は読み込まない)" ;;
        2)  echo "enable_guc=2 (HuC を読み込む)" ;;
        3)  echo "enable_guc=3 (GuC と HuC を読み込む)" ;;
        "") echo "不明 (/sys/module/i915/parameters/enable_guc を読めない)" ;;
        *)  echo "enable_guc=$v" ;;
      esac
      ;;
    *) echo "不明 (カーネルドライバ ${1:-?})" ;;
  esac
}

check_dri() {
  for DEV in "${DEVICES[@]}"; do
    node="${DEV##*/}"
    sys="/sys/class/drm/$node/device"
    vendor="$(cat "$sys/vendor" 2>/dev/null)"
    devid="$(cat "$sys/device" 2>/dev/null)"
    kdrv="$(basename "$(readlink "$sys/driver" 2>/dev/null)" 2>/dev/null)"
    slot="$(sed -n 's/^PCI_SLOT_NAME=//p' "$sys/uevent" 2>/dev/null)"
    gpu=""
    [ -n "$slot" ] && gpu="$(lspci -s "$slot" 2>/dev/null | cut -d' ' -f2- | sed 's/^[^:]*: //')"

    echo "==== $DEV"
    echo "GPU : ${gpu:-不明} [${vendor:-?}:${devid:-?}] カーネルドライバ ${kdrv:-?} (${slot:-?})"
    KDRV_OF["$DEV"]="$kdrv"
    if [ "$vendor" = 0x8086 ] && [ -n "$devid" ]; then
      echo "世代 : $(intel_gen "$devid") ※デバイス ID からの推定"
      echo "HuC : $(huc_conf "$kdrv")"
    fi

    # VA-API ドライバを選ぶ
    if [ -n "$USER_DRIVER" ]; then
      candidates=("$USER_DRIVER")
    else
      case "$vendor" in
        0x8086) candidates=(iHD i965) ;;
        0x1002) candidates=(radeonsi) ;;
        *)      candidates=("") ;;   # libva に任せる
      esac
    fi
    DRV=""; found=0
    for d in "${candidates[@]}"; do
      if [ -n "$d" ]; then export LIBVA_DRIVER_NAME="$d"; else unset LIBVA_DRIVER_NAME; fi
      if vainfo --display drm --device "$DEV" >"$VAINFO_OUT" 2>&1 && grep -q VAEntrypoint "$VAINFO_OUT"; then
        DRV="$d"; found=1; DRV_OF["$DEV"]="$d"; break
      fi
    done
    if [ "$found" = 0 ]; then
      echo "VA-API ドライバを開けなかった (試したドライバ: ${candidates[*]:-自動})"
      tail -3 "$VAINFO_OUT"
      echo
      continue
    fi
    echo "VA-API : ${DRV:-自動} / $(sed -n 's/.*Driver version: *//p' "$VAINFO_OUT" | head -1)"
    echo

    is_intel=0
    [ "$vendor" = 0x8086 ] && is_intel=1
    case "$DRV" in iHD|i965) is_intel=1 ;; esac

    # vainfo のプロファイルとエントリポイントを読む
    ENT=(); PROFILES=()
    while read -r p e; do
      [ -z "${ENT["$p $e"]:-}" ] || continue
      ENT["$p $e"]=1
      case " ${PROFILES[*]} " in *" $p "*) ;; *) PROFILES+=("$p") ;; esac
    done < <(awk '/VAProfile.*:.*VAEntrypoint/ { gsub(/[ \t]/, ""); split($0, a, ":"); print a[1], a[2] }' "$VAINFO_OUT")

    if [ "$WANT_VAAPI" = 1 ]; then
      echo "-- ドライバが申告しているプロファイル (vainfo)"
      printf '%-24s %-8s %-8s %-8s\n' profile decode encode encodeLP
      for p in "${PROFILES[@]}"; do
        [ "$p" = VAProfileNone ] && continue
        dec=-; enc=-; lpe=-
        has_ent VAEntrypointVLD "$p" && dec=OK
        { has_ent VAEntrypointEncSlice "$p" || has_ent VAEntrypointEncPicture "$p"; } && enc=OK
        has_ent VAEntrypointEncSliceLP "$p" && lpe=OK
        printf '%-24s %-8s %-8s %-8s\n' "${p#VAProfile}" "$dec" "$enc" "$lpe"
      done
      echo

      va_check
      VA_DONE+=("$DEV")
    fi

    if [ "$WANT_QSV" = 1 ] && [ "$is_intel" = 0 ]; then
      echo "-- QSV: Intel GPU ではないので飛ばす"
      echo
    elif [ "$WANT_QSV" = 1 ]; then
      if has_encoder h264_qsv || has_encoder hevc_qsv; then
        qsv_check
        QSV_DONE+=("$DEV")
      else
        echo "-- QSV: この ffmpeg は QSV に対応していないので飛ばす"
        echo
      fi
    fi
  done
}


# ---- おすすめ設定 ----
# 方針: 1 パスで画質優先。品質目標型 (ICQ / CQ) を最優先にし、使えなければ CQP などに落とす
# 出す設定は、最後に同じ GPU で実際にエンコードして通ったものだけにする
REC_HEVC_Q="${REC_HEVC_Q:-22}"
REC_H264_Q="${REC_H264_Q:-20}"

set_driver() {   # set_driver <レンダーノード>
  local d="${DRV_OF[$1]:-}"
  if [ -n "$d" ]; then export LIBVA_DRIVER_NAME="$d"; else unset LIBVA_DRIVER_NAME; fi
}

# 追加オプションの候補を前から順に試し、最初に通ったものを返す
# first_ok <試す関数> <関数の固定引数の数> <固定引数...> -- <候補1> <候補2> ...
first_ok() {
  local fn="$1" n="$2"; shift 2
  local fixed=("${@:1:$n}"); shift "$n"
  [ "$1" = -- ] && shift
  local c
  for c in "$@"; do
    # shellcheck disable=SC2086
    if "$fn" "${fixed[@]}" $c; then squash "$c"; return 0; fi
  done
  return 1
}

squash() { tr -s ' ' <<<"$*" | sed 's/^ //; s/ $//'; }   # 余分な空白を詰める

# コピペ用のコマンドをためておき、各セクションの最後にまとめて出す
# インターレース解除つきのコマンドは、通常のコマンドの後ろにまとめて出す
EX_LBL=() EX_CMD=() DEI_LBL=() DEI_CMD=()
ex_add() { EX_LBL+=("$1"); EX_CMD+=("$(squash "$2")"); }
dei_add() { DEI_LBL+=("$1"); DEI_CMD+=("$(squash "$2")"); }
ex_print() {
  local i
  EX_LBL+=("${DEI_LBL[@]}") EX_CMD+=("${DEI_CMD[@]}")
  if [ ${#EX_CMD[@]} -gt 0 ]; then
    echo "  コピペ用のコマンド (input.ts / output.mkv を書き換えて使う):"
    for i in "${!EX_CMD[@]}"; do
      echo "    # ${EX_LBL[$i]}"
      echo "    ${EX_CMD[$i]}"
    done
  fi
  EX_LBL=() EX_CMD=() DEI_LBL=() DEI_CMD=()
}

# インターレース解除のフィルタ。VA-API は GPU の deinterlace_vaapi、QSV と NVENC は CPU の bwdif を使う
# どれも 1 フレームに 1 枚出す (60i → 30p)
VA_DEI_8='format=nv12,hwupload,deinterlace_vaapi=rate=frame'
VA_DEI_10='format=nv12,hwupload,deinterlace_vaapi=rate=frame,scale_vaapi=format=p010'
SW_DEI_8='bwdif=mode=send_frame,format=nv12'
SW_DEI_10='bwdif=mode=send_frame,format=p010le'

# 表で OK (QSV は OK* も含む) が1つでもあれば、そのコーデックは使える
avail() {   # avail <キーの先頭 (例: va|/dev/dri/renderD128|HEVC|)>
  local k
  for k in "${!RES[@]}"; do
    [[ "$k" == "$1"* && "${RES[$k]}" == OK* ]] && return 0
  done
  return 1
}

# おすすめ設定の最初に、使えないものを簡潔に書く。何も使えなければ 1 を返す
rec_notice() {   # rec_notice <キーの先頭 (例: va|/dev/dri/renderD128)>
  local p="$1" hevc=0 h264=0
  avail "$p|HEVC|" && hevc=1
  avail "$p|H.264|" && h264=1
  if [ "$hevc" = 0 ] && [ "$h264" = 0 ]; then
    echo "  HEVC も H.264 も使えないので出力しません。"
    return 1
  fi
  [ "$hevc" = 0 ] && echo "  HEVC は使えないので出力しません。"
  if [ "$hevc" = 1 ] && ! avail "$p|HEVC-10bit|"; then
    echo "  10bit エンコードは使えないので出力しません。"
  fi
  [ "$h264" = 0 ] && echo "  H.264 は使えないので出力しません。"
  return 0
}

rec_line() {   # rec_line <見出し> <オプション文字列>
  printf '  %-11s: %s\n' "$1" "$(squash "$2")"
}

# 経路の名前 (low_power auto はエントリポイントの有無から判断する)
va_path() {   # va_path <レンダーノード> <コーデック> <low_power>
  case "$3" in
    0) echo "通常 (VME)" ;;
    1) echo "低電力 (VDEnc)" ;;
    *) if [ -n "${RES["va|$1|$2|has0"]:-}" ]; then echo "通常 (VME)"; else echo "低電力 (VDEnc)"; fi ;;
  esac
}

# 低電力の経路しかなく、そこで CQP だけが通るなら、HuC が読み込まれていないと判断する
va_huc_missing() {   # va_huc_missing <レンダーノード> <コーデック>
  local dev="$1" name="$2" lp rc
  [ -n "${RES["va|$dev|$name|has1"]:-}" ] && [ -z "${RES["va|$dev|$name|has0"]:-}" ] || return 1
  [ "${RES["va|$dev|$name|1|CQP"]:-}" = OK ] || return 1
  for lp in auto 1; do
    for rc in CBR VBR ICQ QVBR AVBR; do
      [ "${RES["va|$dev|$name|$lp|$rc"]:-}" = OK ] && return 1
    done
  done
  return 0
}

# 上限付き (QVBR) の目標と上限 [Mbps]
#   名前 | コーデック | 目標 | 上限
VA_CAP_ROWS=(
  "HEVC GR|HEVC|6|9"
  "HEVC BS/CS|HEVC|8|12"
  "H.264 GR|H.264|8|10"
  "H.264 BS/CS|H.264|11|14"
)

rec_vaapi() {
  local dev="$1" name enc q qp lp rc lp_opt rc_opt base extra line huc_hint=0
  set_driver "$dev"
  DEV="$dev"
  echo "-- VA-API ($dev)"
  if ! rec_notice "va|$dev"; then echo; return; fi
  for name in HEVC H.264; do
    avail "va|$dev|$name|" || continue
    case "$name" in
      HEVC)  enc=hevc_vaapi q="$REC_HEVC_Q" ;;
      H.264) enc=h264_vaapi q="$REC_H264_Q" ;;
    esac
    qp=$((q - 1))
    # レート制御と low_power の組み合わせを、優先順に探す
    line=""
    for rc in ICQ QVBR CQP VBR; do
      for lp in auto 0 1; do
        [ "${RES["va|$dev|$name|$lp|$rc"]:-}" = OK ] || continue
        case "$lp" in auto) lp_opt="" ;; *) lp_opt="-low_power $lp" ;; esac
        case "$rc" in
          ICQ)  rc_opt="-rc_mode ICQ -global_quality $q" ;;
          QVBR) rc_opt="-rc_mode QVBR -global_quality $q -b:v 8M -maxrate 20M" ;;
          CQP)  rc_opt="-rc_mode CQP -qp $qp -i_qfactor 1 -i_qoffset -2 -b_qfactor 1 -b_qoffset 2" ;;
          VBR)  rc_opt="-rc_mode VBR -b:v 8M -maxrate 15M" ;;
        esac
        base="$lp_opt $rc_opt"
        # shellcheck disable=SC2086
        if extra=$(first_ok va_try 2 "$enc" nv12 -- "$base -compression_level 1 -bf 2" "$base -bf 2" "$base -compression_level 1" "$base"); then
          line="-c:v $enc $extra"
          rec_line "$name" "$line"
          echo "               経路: $(va_path "$dev" "$name" "$lp")"
          if va_huc_missing "$dev" "$name"; then
            echo "               (低電力の経路しかなく、HuC が読み込まれていないため CQP しか使えない)"
            huc_hint=1
          elif [ "$rc" != ICQ ]; then
            echo "               ($rc を使用。ICQ はこの GPU では使えない)"
          fi
          ex_add "$name" "ffmpeg -vaapi_device $dev -i input.ts -vf 'format=nv12,hwupload' $line -c:a copy output.mkv"
          # shellcheck disable=SC2086
          if VA_VF="$VA_DEI_8" va_try "$enc" nv12 $extra; then
            dei_add "$name(インターレース解除)" "ffmpeg -vaapi_device $dev -i input.ts -vf '$VA_DEI_8' $line -c:a copy output.mkv"
          fi
          # 10bit も同じ設定で通るか
          if [ "$name" = HEVC ] && [ "${RES["va|$dev|HEVC-10bit|$lp|$rc"]:-}" = OK ]; then
            # shellcheck disable=SC2086
            if va_try "$enc" p010 $extra -profile:v main10; then
              rec_line "HEVC(10bit)" "$line -profile:v main10"
              ex_add "HEVC(10bit)" "ffmpeg -vaapi_device $dev -i input.ts -vf 'format=p010,hwupload' $line -profile:v main10 -c:a copy output.mkv"
              # shellcheck disable=SC2086
              if VA_VF="$VA_DEI_10" va_try "$enc" p010 $extra -profile:v main10; then
                dei_add "HEVC(10bit, インターレース解除)" "ffmpeg -vaapi_device $dev -i input.ts -vf '$VA_DEI_10' $line -profile:v main10 -c:a copy output.mkv"
              fi
            fi
          fi
          break 2
        fi
      done
    done
    [ -z "$line" ] && rec_line "$name" "(使える設定が無い)"
  done
  if [ "${RES["va|$dev|AV1|auto|ICQ"]:-}" = OK ] || [ "${RES["va|$dev|AV1|auto|CQP"]:-}" = OK ]; then
    echo "  AV1 もエンコードできる (av1_vaapi。品質値の尺度が HEVC と違うので、値は試して決める)"
  fi
  rec_vaapi_cap "$dev"
  ex_print
  if [ "$huc_hint" = 1 ]; then
    echo "  HuC を有効にしてから測定し直すと、ICQ と上限付き (QVBR) の設定も確かめられる:"
    if [ "${KDRV_OF[$dev]:-}" = xe ]; then
      echo "    xe ドライバは HuC を自動で読み込むので、HuC のファームウェア (linux-firmware) が入っているかを確かめる"
    else
      echo "    1. カーネルのパラメータに i915.enable_guc=2 を足す"
      echo "       (例: /etc/default/grub の GRUB_CMDLINE_LINUX_DEFAULT に追記して、sudo update-grub)"
      echo "    2. 再起動して、もう一度 hwenc-check を実行する"
    fi
  fi
  echo
}

# 上限付き (QVBR) の設定。表で QVBR が通った経路で、実際にエンコードが通ったものだけを出す
rec_vaapi_cap() {   # rec_vaapi_cap <レンダーノード>
  local dev="$1" r label name tgt max enc q lp lp_opt base extra line="" shown=0
  for r in "${VA_CAP_ROWS[@]}"; do
    IFS='|' read -r label name tgt max <<<"$r"
    case "$name" in
      HEVC)  enc=hevc_vaapi q="$REC_HEVC_Q" ;;
      H.264) enc=h264_vaapi q="$REC_H264_Q" ;;
    esac
    for lp in auto 0 1; do
      [ "${RES["va|$dev|$name|$lp|QVBR"]:-}" = OK ] || continue
      case "$lp" in auto) lp_opt="" ;; *) lp_opt="-low_power $lp" ;; esac
      base="$lp_opt -rc_mode QVBR -global_quality $q -b:v ${tgt}M -maxrate ${max}M -bufsize $((max * 2))M"
      if extra=$(first_ok va_try 2 "$enc" nv12 -- "$base -compression_level 1 -bf 2" "$base -bf 2" "$base -compression_level 1" "$base"); then
        if [ "$shown" = 0 ]; then
          echo "  上限付き (QVBR。ファイルを元の TS の 2/3 程度に収める。GR = 1440x1080、BS/CS = 1920x1080):"
          shown=1
        fi
        line="-c:v $enc $extra"
        rec_line "$label" "$line"
        dei_add "$label 上限付き(インターレース解除)" "ffmpeg -vaapi_device $dev -i input.ts -vf '$VA_DEI_8' $line -c:a copy output.mkv"
        line="ok"
        break
      fi
      line=""
    done
    if [ "${line:-}" != ok ] && va_huc_missing "$dev" "$name"; then
      if [ "$shown" = 0 ]; then
        echo "  上限付き (QVBR。ファイルを元の TS の 2/3 程度に収める。GR = 1440x1080、BS/CS = 1920x1080):"
        shown=1
      fi
      rec_line "$label" "(HuC が読み込まれていないため確かめられない。下の手順で HuC を有効にして測定し直す)"
    fi
  done
  if [ "$shown" = 0 ]; then
    echo "  上限付き (QVBR): この GPU では QVBR が通らなかった"
  fi
}

qsv_run() {   # qsv_run <エンコーダ> <pix_fmt> <ICQ を確かめるか 0/1> [オプション...]
  local enc="$1" fmt="$2" want_icq="$3" log; shift 3
  log=$(ffmpeg -hide_banner -nostdin -v verbose \
          -init_hw_device "qsv=qs:hw,child_device=$DEV" -filter_hw_device qs \
          -f lavfi -i "testsrc2=size=$SIZE:rate=30" -frames:v 10 \
          -vf "${QSV_VF:-format=$fmt}" -c:v "$enc" "$@" -f null - 2>&1) || return 1
  [ "$want_icq" = 0 ] && return 0
  grep -i ratecontrol <<<"$log" | grep -E '\b(LA_)?ICQ\b' >/dev/null
}

rec_qsv() {
  local dev="$1" name enc q rc rc_opt want extra line
  set_driver "$dev"
  DEV="$dev"
  echo "-- QSV ($dev)"
  if ! rec_notice "qsv|$dev"; then echo; return; fi
  for name in HEVC H.264; do
    avail "qsv|$dev|$name|" || continue
    case "$name" in
      HEVC)  enc=hevc_qsv q="$REC_HEVC_Q" ;;
      H.264) enc=h264_qsv q="$REC_H264_Q" ;;
    esac
    line=""
    for rc in ICQ CQP VBR; do
      [ "${RES["qsv|$dev|$name|$rc"]:-}" = OK ] || continue
      want=0
      case "$rc" in
        ICQ) rc_opt="-global_quality $q"; want=1 ;;
        CQP) rc_opt="-q:v $((q - 1))" ;;
        VBR) rc_opt="-b:v 8M -maxrate 15M" ;;
      esac
      if extra=$(first_ok qsv_run 3 "$enc" nv12 "$want" -- \
                   "$rc_opt -preset slow -extbrc 1 -look_ahead_depth 40" "$rc_opt -preset slow" "$rc_opt"); then
        line="-c:v $enc $extra"
        rec_line "$name" "$line"
        [ "$rc" != ICQ ] && echo "               ($rc を使用。ICQ はこの GPU では使えない)"
        ex_add "$name" "ffmpeg -init_hw_device qsv=qs:hw,child_device=$dev -i input.ts -vf format=nv12 $line -c:a copy output.mkv"
        # shellcheck disable=SC2086
        if QSV_VF="$SW_DEI_8" qsv_run "$enc" nv12 0 $extra; then
          dei_add "$name(インターレース解除)" "ffmpeg -init_hw_device qsv=qs:hw,child_device=$dev -i input.ts -vf $SW_DEI_8 $line -c:a copy output.mkv"
        fi
        if [ "$name" = HEVC ] && [ "${RES["qsv|$dev|HEVC-10bit|$rc"]:-}" = OK ]; then
          # shellcheck disable=SC2086
          if qsv_run "$enc" p010le "$want" $extra -profile:v main10; then
            rec_line "HEVC(10bit)" "$line -profile:v main10"
            ex_add "HEVC(10bit)" "ffmpeg -init_hw_device qsv=qs:hw,child_device=$dev -i input.ts -vf format=p010le $line -profile:v main10 -c:a copy output.mkv"
            # shellcheck disable=SC2086
            if QSV_VF="$SW_DEI_10" qsv_run "$enc" p010le 0 $extra -profile:v main10; then
              dei_add "HEVC(10bit, インターレース解除)" "ffmpeg -init_hw_device qsv=qs:hw,child_device=$dev -i input.ts -vf $SW_DEI_10 $line -profile:v main10 -c:a copy output.mkv"
            fi
          fi
        fi
        break
      fi
    done
    [ -z "$line" ] && rec_line "$name" "(使える設定が無い)"
  done
  ex_print
  echo
}

rec_nvenc() {
  local gpu="$1" name enc q rc_opt feat extra line gpu_opt=""
  [ ${#NV_GPUS[@]} -gt 1 ] && gpu_opt="-gpu $gpu"
  echo "-- NVENC (GPU $gpu)"
  if ! rec_notice "nv|$gpu"; then echo; return; fi
  for name in HEVC H.264; do
    avail "nv|$gpu|$name|" || continue
    case "$name" in
      HEVC)  enc=hevc_nvenc q=$((REC_HEVC_Q + 1)) ;;
      H.264) enc=h264_nvenc q=$((REC_H264_Q + 1)) ;;
    esac
    ok() { [ "${RES["nv|$gpu|$name|$1"]:-}" = OK ]; }
    if ok CQ; then
      rc_opt="-rc vbr -cq $q -b:v 0 -maxrate 20M -bufsize 40M"
    elif ok CQP; then
      rc_opt="-rc constqp -qp $((q - 2))"
    else
      rec_line "$name" "(使える設定が無い)"
      continue
    fi
    feat=""
    if ok Bframe; then
      feat="-bf 3"
      ok BrefMid && feat="$feat -b_ref_mode middle"
    else
      feat="-bf 0"
    fi
    ok Lookahead && feat="$feat -rc-lookahead 20"
    ok SpatialAQ && feat="$feat -spatial_aq 1 -aq-strength 8"
    ok TemporalAQ && ok Lookahead && feat="$feat -temporal_aq 1"
    if extra=$(first_ok nv_try 3 "$enc" nv12 "$gpu" -- \
                 "-preset p6 -tune hq $rc_opt $feat" "-preset p6 $rc_opt $feat" "-preset p6 $rc_opt -bf 0"); then
      line="-c:v $enc $extra"
      rec_line "$name" "$line"
      ok CQ || echo "               (CQP を使用。CQ はこの GPU では使えない)"
      ok Multipass && echo "               -multipass qres を足すと少し画質が上がる (速度への影響は GPU とプリセットによる)"
      ex_add "$name" "ffmpeg -i input.ts -vf format=nv12 $line $gpu_opt -c:a copy output.mkv"
      # shellcheck disable=SC2086
      if NV_VF="$SW_DEI_8" nv_try "$enc" nv12 "$gpu" $extra; then
        dei_add "$name(インターレース解除)" "ffmpeg -i input.ts -vf $SW_DEI_8 $line $gpu_opt -c:a copy output.mkv"
      fi
      if [ "$name" = HEVC ] && [ "${RES["nv|$gpu|HEVC-10bit|CQ"]:-}" = OK ]; then
        # shellcheck disable=SC2086
        if nv_try "$enc" p010le "$gpu" $extra -profile:v main10; then
          rec_line "HEVC(10bit)" "$line -profile:v main10"
          ex_add "HEVC(10bit)" "ffmpeg -i input.ts -vf format=p010le $line -profile:v main10 $gpu_opt -c:a copy output.mkv"
          # shellcheck disable=SC2086
          if NV_VF="$SW_DEI_10" nv_try "$enc" p010le "$gpu" $extra -profile:v main10; then
            dei_add "HEVC(10bit, インターレース解除)" "ffmpeg -i input.ts -vf $SW_DEI_10 $line -profile:v main10 $gpu_opt -c:a copy output.mkv"
          fi
        fi
      fi
    else
      rec_line "$name" "(使える設定が無い)"
    fi
  done
  if [ "${RES["nv|$gpu|AV1|CQ"]:-}" = OK ]; then
    echo "  AV1 もエンコードできる (av1_nvenc。cq の尺度が HEVC と違うので、値は試して決める)"
  fi
  ex_print
  echo
}

recommend() {
  local d g
  echo
  echo "==== おすすめのエンコード設定"
  echo "方針: 1 パスで画質優先。品質目標型 (ICQ / CQ) を優先し、使えなければ CQP などにする"
  echo "      品質値は小さいほど高画質・大容量 (HEVC $REC_HEVC_Q / H.264 $REC_H264_Q。REC_HEVC_Q / REC_H264_Q で変えられる)"
  echo "      ここに出した設定は、この GPU で実際にエンコードが通ったもの"
  echo
  for d in "${VA_DONE[@]}"; do rec_vaapi "$d"; done
  for d in "${QSV_DONE[@]}"; do rec_qsv "$d"; done
  for g in "${NV_DONE[@]}"; do rec_nvenc "$g"; done
}

# ---- 本体 ----
echo "CPU : $(grep -m1 'model name' /proc/cpuinfo | sed 's/.*: //')"
echo "ffmpeg : $(ffmpeg -hide_banner -version 2>/dev/null | head -1 | cut -d' ' -f3)"
targets=()
[ "$WANT_VAAPI" = 1 ] && targets+=(vaapi)
[ "$WANT_QSV" = 1 ] && targets+=(qsv)
[ "$WANT_NVENC" = 1 ] && targets+=(nvenc)
echo "対象 : ${targets[*]}"
echo

[ "$WANT_VAAPI$WANT_QSV" != 00 ] && check_dri
[ "$WANT_NVENC" = 1 ] && check_nvenc

echo "凡例: OK = 使える / NG = 使えない / - = ドライバが申告していないので試していない"
if [ "$WANT_VAAPI" = 1 ]; then
  cat <<'EOF'
      encodeLP = 低電力エンコード (VAEntrypointEncSliceLP)
      low_power auto = -low_power を付けない (普段の使い方。どちらの経路になるかは ffmpeg に任せる)
                0    = 通常の経路 (VME / シェーダー併用)
                1    = 固定機能の低電力経路 (VDEnc)
EOF
fi
[ "$WANT_QSV" = 1 ] && echo "      OK* = エンコードはできたが、狙いと違うレート制御で動いた (QSV)"
if [ "$WANT_NVENC" = 1 ]; then
  cat <<'EOF'
      NVENC: CQP = -rc constqp、CQ = -rc vbr -cq (品質目標)、レート制御の表は B フレームなし (-bf 0)
             BrefMid = B フレームを参照に使う (-b_ref_mode middle)、TemporalAQ は lookahead と併用
             Multipass = -multipass qres (1/4 解像度の下見)
EOF
fi

[ "$RECOMMEND" = 1 ] && recommend
exit 0
