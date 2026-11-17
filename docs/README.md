# docs

GitHub Pages で公開するドキュメントのソース（Jekyll + [Just the Docs](https://just-the-docs.com/)）。

- 公開: Settings → Pages → Build and deployment を「Deploy from a branch」、ブランチを `main`、フォルダを `/docs` にする
- ページを足すときは、先頭の front matter に `title` と `nav_order`（子ページなら `parent` も）を書く
- ページ間のリンクは `getting-started.html` のように `.html` までつけて書く
- `_includes/` はテーマへの差し込み。日本語で検索できるようにする処理（`lunr/custom-index.js`）と、日本語入力の確定で検索を走らせる処理（`head_custom.html`）がある。テーマはHTMLを1行に圧縮するので、`head_custom.html` のスクリプトに `//` コメントは使わない

## 日本語と英語

日本語のページはルート、英語のページは `en/` 以下の同じパスに置く（`getting-started.md` と `en/getting-started.md`）。ページの言語は `_config.yml` の `defaults` が置き場所から決めるので、front matter に `lang` は書かなくてよい。

- ヘッダーの切り替えリンク（`_includes/header_custom.html`）は、URL の `/en` の有無で対訳ページを探す（`_includes/lang_twin.html`）。対訳が無ければ、もう一方の言語のトップに飛ぶ
- サイドバーはテーマが全ページ共通で1回だけ作ってキャッシュするので、両方の言語を並べたうえで、各項目に付けた `lang` を見て、表示中でない言語を CSS で隠している
- 検索は、表示中のページと同じ言語の文書だけを対象にする（`_includes/lunr/custom-index.js`）
- トップページの文言は `_data/landing.yml` に言語ごとに書く。`{ ... }` の中で英文にカンマを含む値は、必ず引用符で囲む（囲まないとカンマで切れる）
- 注記の見出し（メモ / Note など）は `_sass/custom/custom.scss` で言語ごとに付ける

次のテーマのファイルは、v0.12.0 から写して数行だけ変えている。テーマのバージョンを上げるときは、元のファイルと見比べて写し直す。

| ファイル | 変えたところ |
|---|---|
| `_layouts/default.html` | `<html lang>` をページの言語にする |
| `_includes/components/nav/links.html` | ナビの各項目にページの言語を付ける |
| `_includes/components/sidebar.html` | 題字のリンク先を、表示中の言語のトップにする |
| `_includes/components/footer.html` | 「ページの先頭へ」「このページを編集」を言語で切り替える |

## デザイン

「落花（らっか）」と Ruby の朱がテーマ。和紙の地、墨の文字、朱の差し色で、トップページでは Ruby の宝石のように面のついた花びらが舞う。

| ファイル | 内容 |
|---|---|
| `_layouts/landing.html` / `assets/css/landing.css` | トップページ（サイドバーなしの専用レイアウト）。文言は `_data/landing.yml`、`index.md`（英語は `en/index.md`）の本文はコード例の欄に入る |
| `_sass/custom/setup.scss` | 色の名前（和紙・墨・朱など）と注記の色 |
| `_sass/color_schemes/rakka.scss` | テーマの変数への割り当て（`_config.yml` の `color_scheme: rakka`） |
| `_sass/custom/custom.scss` | ドキュメントページの見た目（明朝の見出し、墨のコードブロック、注記など） |
| `_includes/title.html` | サイドバーの題字（落款 + Rakka） |
| `assets/js/petals.js` | トップページで散り続ける花びら。ページの底（フッターの下）に積もり、途中を読んでいる間は画面の下を通り抜ける。フッターの一言（散っても／また咲く）を押すと、巻き戻してから同じように散り直す |

- `.scss` には ASCII 以外の文字を書かない。Sass はビルド環境の既定の文字コードで読むので、UTF-8 でない環境では日本語のコメントでビルドが止まる。注記の見出し（`_config.yml` の `callouts`）も CSS のエスケープで書いている
- 花びらの動きは、生まれた時刻と乱数から決まる値（イベント）と経過時間だけで決まる純粋な関数（`place`）。積もる位置も散った順番だけで決まるので、巻き戻して再生すると同じ場所に積もり直す。押せることは見せない（遊びとして、気づいた人だけのもの）。動きを減らす設定のときはキャンバスを使わず、ヒーローの静止した花びらになる
- トップページの色を変えるときは、`landing.css` の `:root` と `setup.scss` の両方を揃える

手元で確かめるときは、Ruby 3.3 で `github-pages` gem を使う（GitHub Pages と同じ Jekyll 3.10）。テーマは `remote_theme` で取りに行くので、取れない環境では `just-the-docs` gem を入れて `theme: just-the-docs` / `remote_theme: false` の設定を重ねてビルドする。
