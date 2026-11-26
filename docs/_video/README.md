# 背景動画（Remotion）

トップページの背景に流す動画のソース。屏風に花びらが散り、水面に落ちて波紋が広がる。24 秒で一巡りし、最後のコマから最初のコマへ継ぎ目なくつながる。

- 背景: 長谷川等伯「松林図屏風」左隻（東京国立博物館、国宝）。Wikimedia Commons の [left hand screen](https://commons.wikimedia.org/wiki/File:Hasegawa_Tohaku_-_Pine_Trees_(Sh%C5%8Drin-zu_by%C5%8Dbu)_-_left_hand_screen.jpg)（パブリックドメイン）から、縁の内側を 16:9 で切り出したもの（`public/byobu.jpg`）
- 花びら: 鉤勒（墨の細い輪郭）に胡粉と淡い臙脂を差した桜。紙の粒立ちと縁のにじみは SVG のフィルタで出す
- 波紋: 手前が太く奥が細い墨の輪。かすれで途切れる

## 書き出し

```bash
cd docs/_video
npm install
npm run studio   # ブラウザで確かめながら調整する
npm run render   # ../assets/video/rakka.mp4 と、最初のコマの ../assets/video/rakka.jpg を書き出す
```

Remotion が Chrome を取得できない環境では、`--browser-executable` で手元の Chrome（headless shell）を指定する。

Remotion は個人や3人以下の組織なら無料で使える。それより大きな組織で使うときは、Remotion のライセンスを確認すること。
