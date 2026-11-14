# docker-hwenc-check

GPU がどのコーデックとレート制御でハードウェアエンコードできるかを、コンテナ1つで調べるツールです。
ホストに ffmpeg やドライバを入れなくても、GPU をコンテナに渡すだけで確認できます。

調べられるのは次の3種類です。

| 対象 | GPU | 調べる内容 |
|---|---|---|
| `vaapi` | Intel (iHD / i965)、AMD (radeonsi) | vainfo のプロファイル一覧と、コーデック × low_power × レート制御 (CQP / CBR / VBR / ICQ / QVBR / AVBR) の対応表 |
| `qsv` | Intel | コーデック × レート制御 (CQP / ICQ / VBR / CBR) の対応表 |
| `nvenc` | NVIDIA | レート制御 (CQP / CQ / VBR / CBR) の対応表と、B フレーム・lookahead・AQ・multipass の対応表 |

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

ビルド時に `--build-arg BASE_IMAGE=...` でベースイメージを変えられます (既定 `debian:trixie-slim`)。

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
| `libmfx-gen1.2` | Intel Tiger Lake 以降の QSV ランタイム (oneVPL) |
| `i965-va-driver-shaders` | Intel Haswell 以前の VA-API ドライバ (リポジトリにあるときだけ入れる) |
| `libmfx1` | Intel Ice Lake 以前の QSV ランタイム (リポジトリにあるときだけ入れる) |

NVIDIA のパッケージはイメージに入っていません。ffmpeg は NVENC のライブラリを実行時に読み込み、そのライブラリと `nvidia-smi` は `--gpus` を付けたときに NVIDIA Container Toolkit がホストから渡します (イメージで `NVIDIA_DRIVER_CAPABILITIES=video,utility` を指定しています)。

## うまくいかないとき

- **「レンダーノードが見つからない」と出る**: `docker run` に `--device /dev/dri` を付けてください。
- **「NVIDIA GPU が見えない」と出る**: ホストに NVIDIA Container Toolkit が入っているか、`docker run` に `--gpus all` を付けたかを確認してください。
- **QSV が「この ffmpeg は QSV に対応していない」と出る**: ベースイメージの ffmpeg が QSV なしでビルドされています。`BASE_IMAGE` で別のディストリビューションを試してください。
- **古い Intel GPU で QSV が全部 NG になる**: Ice Lake 以前の GPU は Media SDK (`libmfx1`) が必要です。ベースイメージのリポジトリに `libmfx1` が無いと入らないので、ビルドログで確認してください。
- **VA-API ドライバを開けなかったと出る**: `LIBVA_DRIVER_NAME` でドライバを指定して試してください (Haswell 以前の Intel は `i965`)。

## ファイル

| ファイル | 内容 |
|---|---|
| `Dockerfile` | イメージの定義 |
| `hwenc-check.sh` | テスト本体。イメージでは `/usr/local/bin/hwenc-check` に置かれる |

