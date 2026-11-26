// 最初のコマを、動画を再生しないとき（動きを減らす設定・読み込み中）に見せる JPEG にする
import { execFileSync } from 'node:child_process';
execFileSync('ffmpeg', ['-loglevel', 'error', '-y', '-i', 'out/poster.png', '-q:v', '5', '../assets/video/rakka.jpg'], { stdio: 'inherit' });
