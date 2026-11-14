# docker-hwenc-check

GPU がどのコーデックとレート制御でハードウェアエンコードできるかを、コンテナ1つで調べるツールです。
ホストに ffmpeg やドライバを入れなくても、GPU をコンテナに渡すだけで確認できます。

調べられるのは次の3種類です。

| 対象 | GPU | 調べる内容 |
|---|---|---|
| `vaapi` | Intel (iHD / i965)、AMD (radeonsi) | vainfo のプロファイル一覧と、コーデック × low_power × レート制御 (CQP / CBR / VBR / ICQ / QVBR / AVBR) の対応表 |
| `qsv` | Intel | コーデック × レート制御 (CQP / ICQ / VBR / CBR) の対応表 |
| `nvenc` | NVIDIA | レート制御 (CQP / CQ / VBR / CBR) の対応表と、B フレーム・lookahead・AQ・multipass の対応表 |

`--recommend` を付けると、結果からおすすめのエンコード設定 (ffmpeg のオプション) も出します。

vainfo が申告している内容をそのまま信じるのではなく、ffmpeg で短いテスト映像を実際にエンコードして、通ったものだけを OK にします。
ドライバの申告と ffmpeg から実際に使える範囲は一致しないことがあるので (たとえば低電力経路では CQP しか使えないなど)、その差もここで分かります。

## 必要なもの

- Docker (BuildKit が有効なもの。最近の Docker なら標準で有効)
- Intel / AMD を調べるとき: ホストで `/dev/dri/renderD*` が見えていること
- NVIDIA を調べるとき: ホストに NVIDIA ドライバと [NVIDIA Container Toolkit](https://github.com/NVIDIA/nvidia-container-toolkit)

## 使い方

```bash
docker build -t hwenc-check .
```

調べる対象をコマンドの最後に書きます。

```bash
docker run --rm --device /dev/dri hwenc-check qsv     # Intel の QSV だけ
docker run --rm --device /dev/dri hwenc-check vaapi   # VA-API だけ (Intel / AMD)
docker run --rm --device /dev/dri hwenc-check intel   # VA-API と QSV
docker run --rm --gpus all hwenc-check nvenc          # NVIDIA の NVENC だけ
docker run --rm --device /dev/dri --gpus all hwenc-check all
```

対象は `qsv nvenc` のように複数並べても構いません。省略すると、コンテナから見える GPU に合わせて自動で選びます (`/dev/dri` があれば vaapi と qsv、NVIDIA GPU があれば nvenc)。
必要なデバイスが渡されていないときは、付けるべきオプションを表示して止まります。

結果からおすすめのエンコード設定も出したいときは、`-r` (`--recommend`) を付けます。

```bash
docker run --rm --device /dev/dri hwenc-check -r qsv
docker run --rm --gpus all -e RECOMMEND=1 hwenc-check nvenc
```

GPU が複数あるときは全部を順に調べます。1つに絞るときは環境変数で指定します。

```bash
docker run --rm --device /dev/dri -e VAAPI_DEVICE=/dev/dri/renderD129 hwenc-check vaapi
docker run --rm --gpus all -e NVENC_GPU=1 hwenc-check nvenc
```

## 環境変数

| 変数 | 内容 | 既定 |
|---|---|---|
| `TARGET` | 引数の代わりに調べる対象を指定する (例 `qsv nvenc`)。引数があれば引数が優先 | 自動 |
| `VAAPI_DEVICE` | 調べるレンダーノード | `/dev/dri/renderD*` を全部 |
| `LIBVA_DRIVER_NAME` | VA-API ドライバ (`iHD` / `i965` / `radeonsi`) | ベンダーから自動で選ぶ (Intel は iHD → i965 の順) |
| `NVENC_GPU` | 調べる NVIDIA GPU の番号 | 全部 |
| `SIZE` | テスト映像の解像度 | `1920x1080` |
| `RECOMMEND` | `1` で `--recommend` と同じ。`--no-recommend` を付けると引数が優先 | `0` |
| `REC_HEVC_Q` | おすすめ設定で使う HEVC の品質値 (NVENC の cq はこれに +1) | `22` |
| `REC_H264_Q` | おすすめ設定で使う H.264 の品質値 (NVENC の cq はこれに +1) | `20` |

ビルド時に `--build-arg BASE_IMAGE=...` でベースイメージを変えられます (既定 `debian:trixie-slim`)。

### 古い Intel GPU の QSV (libmfx1)

Ice Lake 以前の Intel GPU (Broadwell〜Ice Lake。Kaby Lake や Coffee Lake を含む) で QSV を使うには、Intel Media SDK のランタイム (`libmfx1`) が必要です。
`libmfx1` は Debian trixie で削除されたので、このイメージではベースイメージのリポジトリに無いとき、`libmfx1` だけを bookworm のリポジトリから入れます (依存するライブラリはベースイメージのものを使い、入れ終わったら bookworm のリポジトリは外します)。
ffmpeg の QSV (oneVPL のディスパッチャ) は、新しいランタイム (`libmfx-gen1.2`) が使えない GPU では、このランタイムを読み込みます。

既定で入れるようになっています。Tiger Lake 以降の GPU しか使わず、入れたくないときは無効にしてビルドします。

```bash
docker build --build-arg LIBMFX1=0 -t hwenc-check .
```

## 出力の見方

以下は表示の例です。

### VA-API

```
-- VA-API エンコード (ffmpeg で実際に試した結果)
codec        low_power CQP   CBR   VBR   ICQ   QVBR  AVBR
H.264        auto      OK    OK    OK    OK    OK    NG
H.264        0         OK    OK    OK    OK    OK    NG
H.264        1         OK    NG    NG    NG    NG    NG
HEVC         auto      OK    OK    OK    OK    OK    NG
HEVC         0         OK    OK    OK    OK    OK    NG
HEVC         1         -     -     -     -     -     -
AV1          -         (エンコード非対応)
```

`low_power` の `auto` は `-low_power` を付けないとき、つまり普段の使い方です。`0` は通常の経路 (VME / シェーダー併用)、`1` は固定機能の低電力経路 (VDEnc) です。
自分のスクリプトで `-low_power` を指定していないなら、`auto` の行を見れば足ります。

この表の前に、vainfo が申告しているプロファイルごとのデコード / エンコード / 低電力エンコードの一覧も出ます。

### QSV

```
-- QSV エンコード (ffmpeg で実際に試した結果)
codec                  CQP   ICQ   VBR   CBR
H.264                  OK    OK    OK    OK
HEVC                   OK    OK    OK    OK
AV1                    NG    NG    NG    NG
```

`OK*` は、エンコードはできたものの、ログに出たレート制御が狙いと違ったことを表します (ランタイムが別の方式に切り替えた場合)。

### NVENC

```
-- NVENC レート制御 (ffmpeg で実際に試した結果)
codec        CQP        CQ         VBR        CBR
H.264        OK         OK         OK         OK
HEVC         OK         OK         OK         OK

-- NVENC 機能 (-rc vbr -cq 26 に足して試した結果)
codec        Bframe     BrefMid    Lookahead  SpatialAQ  TemporalAQ Multipass
H.264        OK         NG         OK         OK         OK         OK
HEVC         NG         NG         OK         OK         NG         OK
```

`CQ` は `-rc vbr -cq` による品質目標型です。レート制御の表は、B フレームの対応に左右されないよう `-bf 0` で試しています。
Pascal 世代 (GTX 10 系、Quadro P 系) は HEVC の B フレームに対応していないので、HEVC の `Bframe` が NG になります。

### おすすめ設定 (`--recommend`)

```
==== おすすめのエンコード設定
方針: 1 パスで画質優先。品質目標型 (ICQ / CQ) を優先し、使えなければ CQP などにする
      品質値は小さいほど高画質・大容量 (HEVC 22 / H.264 20。REC_HEVC_Q / REC_H264_Q で変えられる)
      ここに出した設定は、この GPU で実際にエンコードが通ったもの

-- VA-API (/dev/dri/renderD128)
  HEVC       : -c:v hevc_vaapi -rc_mode ICQ -global_quality 22 -compression_level 1 -bf 2
  HEVC(10bit): -c:v hevc_vaapi -rc_mode ICQ -global_quality 22 -compression_level 1 -bf 2 -profile:v main10
  H.264      : -c:v h264_vaapi -rc_mode ICQ -global_quality 20 -compression_level 1 -bf 2
  コピペ用のコマンド (input.ts / output.mkv を書き換えて使う):
    # HEVC
    ffmpeg -vaapi_device /dev/dri/renderD128 -i input.ts -vf 'format=nv12,hwupload' -c:v hevc_vaapi -rc_mode ICQ -global_quality 22 -compression_level 1 -bf 2 -c:a copy output.mkv
    # HEVC(10bit)
    ffmpeg -vaapi_device /dev/dri/renderD128 -i input.ts -vf 'format=p010,hwupload' -c:v hevc_vaapi -rc_mode ICQ -global_quality 22 -compression_level 1 -bf 2 -profile:v main10 -c:a copy output.mkv
    # H.264
    ffmpeg -vaapi_device /dev/dri/renderD128 -i input.ts -vf 'format=nv12,hwupload' -c:v h264_vaapi -rc_mode ICQ -global_quality 20 -compression_level 1 -bf 2 -c:a copy output.mkv
    # HEVC(インターレース解除)
    ffmpeg -vaapi_device /dev/dri/renderD128 -i input.ts -vf 'format=nv12,hwupload,deinterlace_vaapi=rate=frame' -c:v hevc_vaapi -rc_mode ICQ -global_quality 22 -compression_level 1 -bf 2 -c:a copy output.mkv
    # HEVC(10bit, インターレース解除)
    ffmpeg -vaapi_device /dev/dri/renderD128 -i input.ts -vf 'format=nv12,hwupload,deinterlace_vaapi=rate=frame,scale_vaapi=format=p010' -c:v hevc_vaapi -rc_mode ICQ -global_quality 22 -compression_level 1 -bf 2 -profile:v main10 -c:a copy output.mkv
    # H.264(インターレース解除)
    ffmpeg -vaapi_device /dev/dri/renderD128 -i input.ts -vf 'format=nv12,hwupload,deinterlace_vaapi=rate=frame' -c:v h264_vaapi -rc_mode ICQ -global_quality 20 -compression_level 1 -bf 2 -c:a copy output.mkv

-- NVENC (GPU 0)
  HEVC       : -c:v hevc_nvenc -preset p6 -tune hq -rc vbr -cq 23 -b:v 0 -maxrate 20M -bufsize 40M -bf 0 -rc-lookahead 20 -spatial_aq 1 -aq-strength 8
               -multipass qres を足すと少し画質が上がる (速度への影響は GPU とプリセットによる)
  HEVC(10bit): -c:v hevc_nvenc ... -profile:v main10
  ...
  コピペ用のコマンド (input.ts / output.mkv を書き換えて使う):
    # HEVC
    ffmpeg -i input.ts -vf format=nv12 -c:v hevc_nvenc -preset p6 -tune hq -rc vbr -cq 23 -b:v 0 -maxrate 20M -bufsize 40M -bf 0 -rc-lookahead 20 -spatial_aq 1 -aq-strength 8 -c:a copy output.mkv
    # HEVC(10bit)
    ffmpeg -i input.ts -vf format=p010le -c:v hevc_nvenc ... -profile:v main10 -c:a copy output.mkv
    ...
    # HEVC(インターレース解除)
    ffmpeg -i input.ts -vf bwdif=mode=send_frame,format=nv12 -c:v hevc_nvenc ... -c:a copy output.mkv
    ...
```

選び方は、録画のアーカイブのように「1 パスで、多少大きくなっても画質を優先する」用途を想定しています。

- コマンドは、そのままコピペして使える形で出します (`input.ts` と `output.mkv` だけ書き換える)。HEVC が 10bit でも通る GPU では、10bit 用のコマンドも出します
- 放送の録画などインターレースの素材向けに、インターレース解除つきのコマンドも出します。VA-API は GPU の `deinterlace_vaapi`、QSV と NVENC は CPU の `bwdif` を使い、どれも 60i を 30p にします。これも実際に通ったものだけを出します
- コーデックは HEVC と H.264 を出します。AV1 がエンコードできる GPU では、そのことも書きます (品質値の尺度が違うので、値は出しません)
- レート制御は、品質目標型 (VA-API / QSV は ICQ、NVENC は `-rc vbr -cq`) を優先します。使えないときは VA-API は QVBR → CQP → VBR、QSV は CQP → VBR、NVENC は CQP の順に落とします。CQP にするときは、I / B フレームの QP が P フレームから大きくずれないようオフセットを指定します
- VA-API は `-low_power` を付けない経路を優先し、通らないときだけ `-low_power 0` / `1` を付けます
- NVENC は、表で OK だった機能 (B フレーム、B フレーム参照、lookahead、空間 AQ、時間 AQ) を足します。multipass は設定には含めず、使える GPU では `-multipass qres` を足せることを1行添えます。NVENC の multipass は 1 回のエンコードの中でフレームを 2 回解析する方式で、速度への影響は GPU とプリセットによります (重いプリセットではほとんど遅くならない計測もあります)
- `-compression_level 1` や `-preset slow` などの追加オプションは、通る組み合わせを順に試して選びます。出した設定は、同じ GPU で実際にエンコードが通ったものだけです

### 記号

| 記号 | 意味 |
|---|---|
| `OK` | 使える |
| `NG` | 使えない |
| `-` | ドライバが申告していないので試していない |
| `OK*` | (QSV) エンコードはできたが、狙いと違うレート制御で動いた |

## 試しているオプション

どのテストも、`testsrc2` で作った `SIZE` の解像度の映像を 10 フレームだけエンコードして、ffmpeg が成功したかで判定します。
実際の素材の解像度、長さ、フィルタの組み合わせによっては、ここに出ない制限に当たることがあります。

| 対象 | レート制御 / 機能 | ffmpeg のオプション |
|---|---|---|
| VA-API | CQP | `-rc_mode CQP -qp 26` |
| | CBR | `-rc_mode CBR -b:v 6M` |
| | VBR | `-rc_mode VBR -b:v 6M -maxrate 9M` |
| | ICQ | `-rc_mode ICQ -global_quality 26` |
| | QVBR | `-rc_mode QVBR -global_quality 26 -b:v 6M -maxrate 9M` |
| | AVBR | `-rc_mode AVBR -b:v 6M` |
| QSV | CQP | `-q:v 26` |
| | ICQ | `-global_quality 26` |
| | VBR | `-b:v 6M -maxrate 9M` |
| | CBR | `-b:v 6M -maxrate 6M` |
| NVENC | CQP | `-rc constqp -qp 26 -bf 0` |
| | CQ | `-rc vbr -cq 26 -b:v 0 -bf 0` |
| | VBR | `-rc vbr -b:v 6M -maxrate 9M -bf 0` |
| | CBR | `-rc cbr -b:v 6M -bf 0` |
| | Bframe | `-bf 3` |
| | BrefMid | `-bf 3 -b_ref_mode middle` |
| | Lookahead | `-rc-lookahead 20` |
| | SpatialAQ | `-spatial_aq 1` |
| | TemporalAQ | `-rc-lookahead 20 -temporal_aq 1` |
| | Multipass | `-multipass qres` |

NVENC の機能のテストは、どれも `-rc vbr -cq 26 -b:v 0` に足して試します。
10bit の行は、VA-API と QSV では `p010`、NVENC では `p010le` を入力にしています (HEVC は `-profile:v main10`、VA-API の VP9 は `-profile:v 2` を付けます)。

## イメージに入っているもの

| パッケージ | 用途 |
|---|---|
| `ffmpeg`、`vainfo`、`pciutils` | テストと情報表示 |
| `intel-media-va-driver-non-free` | Intel Broadwell 以降の VA-API ドライバ (iHD) |
| `mesa-va-drivers` | AMD の VA-API ドライバ (radeonsi) |
| `libmfx-gen1.2` | Intel Tiger Lake 以降の QSV ランタイム (oneVPL。リポジトリにあるときだけ入れる) |
| `i965-va-driver-shaders` | Intel Haswell 以前の VA-API ドライバ (リポジトリにあるときだけ入れる) |
| `libmfx1` | Intel Ice Lake 以前の QSV ランタイム (Media SDK。`LIBMFX1=1` のとき入れる。ベースイメージに無ければ bookworm から入れる) |

NVIDIA のパッケージはイメージに入っていません。ffmpeg は NVENC のライブラリを実行時に読み込み、そのライブラリと `nvidia-smi` は `--gpus` を付けたときに NVIDIA Container Toolkit がホストから渡します (イメージで `NVIDIA_DRIVER_CAPABILITIES=video,utility` を指定しています)。

## うまくいかないとき

- **「レンダーノードが見つからない」と出る**: `docker run` に `--device /dev/dri` を付けてください。
- **「NVIDIA GPU が見えない」と出る**: ホストに NVIDIA Container Toolkit が入っているか、`docker run` に `--gpus all` を付けたかを確認してください。
- **QSV が「この ffmpeg は QSV に対応していない」と出る**: ベースイメージの ffmpeg が QSV なしでビルドされています。`BASE_IMAGE` で別のディストリビューションを試してください。
- **古い Intel GPU で QSV が全部 NG になる**: Ice Lake 以前の GPU は Media SDK (`libmfx1`) が必要です。QSV の表の上に出る「ランタイム」の行に Media SDK が無ければ、`LIBMFX1=0` でビルドしたイメージを使っています。既定 (`LIBMFX1=1`) でビルドし直してください。
- **VA-API ドライバを開けなかったと出る**: `LIBVA_DRIVER_NAME` でドライバを指定して試してください (Haswell 以前の Intel は `i965`)。

## ファイル

| ファイル | 内容 |
|---|---|
| `Dockerfile` | イメージの定義 |
| `hwenc-check.sh` | テスト本体。イメージでは `/usr/local/bin/hwenc-check` に置かれる |

