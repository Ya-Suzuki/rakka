# docs

GitHub Pages で公開するドキュメントのソース（Jekyll + [Just the Docs](https://just-the-docs.com/)）。

- 公開: Settings → Pages → Build and deployment を「Deploy from a branch」、ブランチを `main`、フォルダを `/docs` にする
- ページを足すときは、先頭の front matter に `title` と `nav_order`（子ページなら `parent` も）を書く
- ページ間のリンクは `getting-started.html` のように `.html` までつけて書く
- `_includes/` はテーマへの差し込み。日本語で検索できるようにする処理（`lunr/custom-index.js`）と、日本語入力の確定で検索を走らせる処理（`head_custom.html`）がある。テーマはHTMLを1行に圧縮するので、`head_custom.html` のスクリプトに `//` コメントは使わない

## デザイン

「落花（らっか）」と Ruby の朱がテーマ。和紙の地、墨の文字、朱の差し色で、トップページでは Ruby の宝石のように面のついた花びらが舞う。

| ファイル | 内容 |
|---|---|
| `_layouts/landing.html` / `assets/css/landing.css` | トップページ（サイドバーなしの専用レイアウト）。`index.md` の本文はコード例の欄に入る |
| `_sass/custom/setup.scss` | 色の名前（和紙・墨・朱など）と注記の色 |
| `_sass/color_schemes/rakka.scss` | テーマの変数への割り当て（`_config.yml` の `color_scheme: rakka`） |
| `_sass/custom/custom.scss` | ドキュメントページの見た目（明朝の見出し、墨のコードブロック、注記など） |
| `_includes/title.html` | サイドバーの題字（落款 + Rakka） |

- `.scss` には ASCII 以外の文字を書かない。Sass はビルド環境の既定の文字コードで読むので、UTF-8 でない環境では日本語のコメントでビルドが止まる。注記の見出し（`_config.yml` の `callouts`）も CSS のエスケープで書いている
- トップページの色を変えるときは、`landing.css` の `:root` と `setup.scss` の両方を揃える

手元で確かめるときは、Ruby 3.3 で `github-pages` gem を使う（GitHub Pages と同じ Jekyll 3.10）。テーマは `remote_theme` で取りに行くので、取れない環境では `just-the-docs` gem を入れて `theme: just-the-docs` / `remote_theme: false` の設定を重ねてビルドする。
