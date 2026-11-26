/*
 * 背景の屏風の動画を流し、フッターの一言で巻き戻す。
 *
 * ブラウザは動画を逆向きに再生できない（負の再生速度は Chrome / Firefox が受け付けず、
 * 少しずつ戻すとキーフレームから解き直すのでカクつく）。そこで、同じ動画を逆向きに
 * 書き出したもう1本を用意しておき、押されたら
 *   1. 今のコマ（t 秒）を止めて、逆向きの動画の D - t 秒（同じ絵）に入れ替える
 *   2. 逆向きの動画を早送り（なめらかに加速して、最後は減速）で最後まで流す = 最初まで巻き戻る
 *   3. 元の動画を 0 秒から流し直して入れ替える
 * 花びらも波紋も時刻だけで決まる絵なので、逆向きの動画はちょうど鏡写しになり、
 * 入れ替えても継ぎ目は出ない。
 */
(function () {
  'use strict';

  var root = document.documentElement;
  var play = document.querySelector('video.byobu--play');
  var rewind = document.querySelector('video.byobu--rewind');
  var poem = document.querySelector('.footer__poem');
  if (!play) return;
  // 動きを減らす設定では流さない（最初のコマを静止画として見せる）
  if (window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches) return;

  var start = function (v) { var p = v.play(); if (p && p.catch) p.catch(function () {}); return p; };
  start(play);
  if (!rewind || !poem || !window.Promise) return;

  var FPS = 30;         // 動画のコマ数（毎秒）。_video/src/Rakka.jsx と同じ
  var MAX_RATE = 8;     // 巻き戻しの最高速度（倍）
  var ACCEL = 5;        // 1秒ごとに上げる速度
  var BRAKE = 2.2;      // 残り1秒あたりの速度（最後はこれで減速する）

  var load = function () {
    if (rewind.preload !== 'auto') { rewind.preload = 'auto'; rewind.load(); }
  };

  // 指定した時刻のコマが出るまで待つ
  var seek = function (v, t) {
    return new Promise(function (resolve) {
      var done = function () { v.removeEventListener('seeked', done); resolve(); };
      v.addEventListener('seeked', done);
      v.currentTime = t;
    });
  };
  var painted = function (v) {
    return new Promise(function (resolve) {
      if (v.requestVideoFrameCallback) v.requestVideoFrameCallback(function () { resolve(); });
      else requestAnimationFrame(function () { requestAnimationFrame(resolve); });
    });
  };
  var whenReady = function (v) {
    return v.readyState >= 1 ? Promise.resolve() : new Promise(function (resolve) {
      v.addEventListener('loadedmetadata', resolve, { once: true });
    });
  };

  var busy = false;
  function replay() {
    if (busy) return;
    busy = true;
    load();
    root.classList.add('is-replaying');
    whenReady(rewind).then(function () {
      play.pause();
      // 元の n コマ目は、逆向きの動画では (総コマ数 - 1 - n) コマ目。そのコマの真ん中へ合わせる
      var frames = Math.round((rewind.duration || play.duration) * FPS);
      var n = Math.min(frames - 1, Math.floor(play.currentTime * FPS));
      return seek(rewind, (frames - 1 - n + 0.5) / FPS);
    }).then(function () {
      root.classList.add('is-rewinding');
      rewind.playbackRate = 1;
      start(rewind);
      return new Promise(function (resolve) {
        var began = performance.now();
        var step = function (now) {
          var left = rewind.duration - rewind.currentTime;
          if (rewind.ended || left < 0.04) { resolve(); return; }
          var rate = Math.min(MAX_RATE, 1 + ACCEL * (now - began) / 1000, 1 + BRAKE * left);
          rewind.playbackRate = Math.max(1, rate);
          requestAnimationFrame(step);
        };
        requestAnimationFrame(step);
      });
    }).then(function () {
      rewind.pause();
      return seek(play, 0);
    }).then(function () {
      start(play);
      return painted(play);
    }).then(function () {
      root.classList.remove('is-rewinding', 'is-replaying');
      busy = false;
    }, function () {
      root.classList.remove('is-rewinding', 'is-replaying');
      start(play);
      busy = false;
    });
  }

  poem.setAttribute('role', 'button');
  poem.setAttribute('tabindex', '0');
  if (poem.dataset.replayLabel) poem.setAttribute('aria-label', poem.dataset.replayLabel);
  poem.addEventListener('pointerenter', load);
  poem.addEventListener('focus', load);
  poem.addEventListener('click', replay);
  poem.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); replay(); }
  });
})();
