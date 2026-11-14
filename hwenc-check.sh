#!/bin/bash
# GPU のハードウェアエンコード対応を調べる
#   vaapi : vainfo のプロファイル一覧と、ffmpeg で実際に試したコーデック × low_power × レート制御の対応表
#   qsv   : Intel GPU の QSV で、コーデック × レート制御の対応表
#   nvenc : NVIDIA GPU の NVENC で、コーデック × レート制御と、B フレーム・AQ などの機能の対応表
#
# 使い方: hwenc-check [vaapi|qsv|nvenc|intel|all ...]
#   intel は vaapi qsv と同じ。省略すると、見えている GPU に合わせて自動で選ぶ
#   (/dev/dri があれば vaapi と qsv、NVIDIA GPU があれば nvenc)
#
# 環境変数:
#   TARGET             引数の代わりに調べる対象を指定する (例: TARGET="qsv nvenc")
#   VAAPI_DEVICE       調べるレンダーノード (未指定なら /dev/dri/renderD* を全部調べる)
#   LIBVA_DRIVER_NAME  VA-API ドライバ (未指定なら GPU のベンダーから選ぶ。Intel は iHD → i965 の順に試す)
#   NVENC_GPU          調べる NVIDIA GPU の番号 (未指定なら全部調べる)
#   SIZE               テスト映像の解像度 (既定 1920x1080)
set -uo pipefail

SIZE="${SIZE:-1920x1080}"
USER_DRIVER="${LIBVA_DRIVER_NAME:-}"
VAINFO_OUT="$(mktemp)"
trap 'rm -f "$VAINFO_OUT"' EXIT

usage() { sed -n '7,9p' "$0" | sed 's/^# \{0,1\}//'; }

# ---- 調べる対象を決める ----
WANT_VAAPI=0 WANT_QSV=0 WANT_NVENC=0
read -r -a REQ <<<"${*:-${TARGET:-}}"
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
elif ldconfig -p 2>/dev/null | grep -q libnvidia-encode; then
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
    -vf "format=$fmt,hwupload" -c:v "$enc" "$@" -f null - >/dev/null 2>&1
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
    if grep -i ratecontrol <<<"$log" | grep -qw "$rc"; then echo OK; else echo 'OK*'; fi
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
  row codec "" "${QSV_COLS[@]}"
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
    done
    row "$name" "" "${cells[@]}"
  done
  echo
}


# ---- NVENC ----
nv_try() {   # nv_try <エンコーダ> <pix_fmt> <GPU 番号> [オプション...]
  local enc="$1" fmt="$2" gpu="$3"; shift 3
  ffmpeg -hide_banner -nostdin -v error \
    -f lavfi -i "testsrc2=size=$SIZE:rate=30" -frames:v 10 \
    -vf "format=$fmt" -c:v "$enc" -gpu "$gpu" "$@" -f null - >/dev/null 2>&1
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
  done
}

# ---- Intel / AMD (/dev/dri) ----
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
        DRV="$d"; found=1; break
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
    fi

    if [ "$WANT_QSV" = 1 ] && [ "$is_intel" = 0 ]; then
      echo "-- QSV: Intel GPU ではないので飛ばす"
      echo
    elif [ "$WANT_QSV" = 1 ]; then
      if has_encoder h264_qsv || has_encoder hevc_qsv; then
        qsv_check
      else
        echo "-- QSV: この ffmpeg は QSV に対応していないので飛ばす"
        echo
      fi
    fi
  done
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
