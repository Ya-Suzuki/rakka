// 日本語で検索できるようにする（テーマの索引作成に差し込まれ、文書ごとに呼ばれる）。
//
// lunr は英語向けで、前処理（trimmer）が英数字以外を削るため、日本語の語がすべて消える。
// そこで、日本語の部分を2文字ずつ（bigram）に区切ってから索引に入れ、検索語も同じように
// 区切る。trimmer は、Unicode の文字と数字を残すものに置き換える。
if (!this.jaSearchReady) {
  this.jaSearchReady = true;

  if (!lunr.jaTokenizer) {
    var original = lunr.tokenizer;
    var cjkRun = /[぀-ヿ㐀-鿿豈-﫿ｦ-ﾟ]+|[^぀-ヿ㐀-鿿豈-﫿ｦ-ﾟ]+/g;
    var isCjk = /[぀-ヿ㐀-鿿豈-﫿ｦ-ﾟ]/;

    var tokenize = function (obj, metadata) {
      var tokens = original(obj, metadata);
      var result = [];

      tokens.forEach(function (token) {
        var str = token.toString();
        if (!isCjk.test(str)) {
          result.push(token);
          return;
        }

        var start = token.metadata.position ? token.metadata.position[0] : 0;
        var offset = 0;
        (str.match(cjkRun) || []).forEach(function (run) {
          var pieces = [];
          if (!isCjk.test(run) || run.length < 2) {
            pieces.push([run, offset, run.length]);
          } else {
            // 2文字ずつ重ねて区切るが、ハイライト用の位置は重ならないように
            // 各語の先頭1文字だけにする（最後の語だけ2文字）。重なると見出しが崩れる
            for (var i = 0; i < run.length - 1; i++) {
              pieces.push([run.slice(i, i + 2), offset + i, i === run.length - 2 ? 2 : 1]);
            }
          }
          pieces.forEach(function (piece) {
            var meta = lunr.utils.clone(token.metadata) || {};
            meta.position = [start + piece[1], piece[2]];
            result.push(new lunr.Token(piece[0], meta));
          });
          offset += run.length;
        });
      });

      return result;
    };
    tokenize.separator = original.separator;

    var trimmer = function (token) {
      return token.update(function (s) {
        return s.replace(/^[^\p{L}\p{N}]+/u, '').replace(/[^\p{L}\p{N}]+$/u, '');
      });
    };
    lunr.Pipeline.registerFunction(trimmer, 'jaTrimmer');

    lunr.jaTokenizer = tokenize;
    lunr.jaTrimmer = trimmer;
    lunr.tokenizer = tokenize; // テーマは検索語の分割にも lunr.tokenizer を使う
  }

  this.tokenizer = lunr.jaTokenizer;
  this.pipeline.before(lunr.trimmer, lunr.jaTrimmer);
  this.pipeline.remove(lunr.trimmer);
}
