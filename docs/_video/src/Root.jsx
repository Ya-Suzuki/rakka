import { Composition } from 'remotion';
import { Rakka, FPS, LOOP } from './Rakka';

export const Root = () => (
  <Composition id="Rakka" component={Rakka} width={1920} height={1080} fps={FPS} durationInFrames={FPS * LOOP} />
);
