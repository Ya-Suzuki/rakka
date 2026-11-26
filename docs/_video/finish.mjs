// 書き出した動画から、ページで使うものを作る
//   rakka.jpg         最初のコマ。動画を再生しないとき（動きを減らす設定・読み込み中）に見せる
//   rakka-rewind.mp4  逆向きの動画。フッターの一言で巻き戻すときに使う（assets/js/byobu.js）。
//                     元の動画と入れ替えても色が変わらないよう、色の範囲（pc / yuvj420p）をそろえる
import { execFileSync } from 'node:child_process';

const ffmpeg = (...args) => execFileSync('ffmpeg', ['-loglevel', 'error', '-y', ...args], { stdio: 'inherit' });
ffmpeg('-i', 'out/poster.png', '-q:v', '5', '../assets/video/rakka.jpg');
ffmpeg('-i', '../assets/video/rakka.mp4', '-vf', 'reverse', '-c:v', 'libx264', '-crf', '29', '-preset', 'slow',
  '-pix_fmt', 'yuvj420p', '-color_range', 'pc', '-colorspace', 'bt470bg', '-g', '90', '-movflags', '+faststart', '-an',
  '../assets/video/rakka-rewind.mp4');
