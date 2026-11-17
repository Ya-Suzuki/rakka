# docs

GitHub Pages で公開するドキュメントのソース（Jekyll + [Just the Docs](https://just-the-docs.com/)）。

- 公開: Settings → Pages → Build and deployment を「Deploy from a branch」、ブランチを `main`、フォルダを `/docs` にする
- ページを足すときは、先頭の front matter に `title` と `nav_order`（子ページなら `parent` も）を書く
- ページ間のリンクは `getting-started.html` のように `.html` までつけて書く
- `_includes/` はテーマへの差し込み。日本語で検索できるようにする処理（`lunr/custom-index.js`）と、日本語入力の確定で検索を走らせる処理（`head_custom.html`）がある。テーマはHTMLを1行に圧縮するので、`head_custom.html` のスクリプトに `//` コメントは使わない

手元で確かめるときは、Ruby 3.3 で `github-pages` gem を使う（GitHub Pages と同じ Jekyll 3.10）。テーマは `remote_theme` で取りに行くので、取れない環境では `just-the-docs` gem を入れて `theme: just-the-docs` / `remote_theme: false` の設定を重ねてビルドする。
