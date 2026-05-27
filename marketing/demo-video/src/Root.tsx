import React from 'react';
import {Composition} from 'remotion';
import {KernDemoVideo} from './KernDemoVideo';

const fps = 30;
const durationInFrames = 24 * fps;

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition
        id="KernTwitterDemoLandscape"
        component={KernDemoVideo}
        durationInFrames={durationInFrames}
        fps={fps}
        width={1920}
        height={1080}
        defaultProps={{layout: 'landscape'}}
      />
      <Composition
        id="KernTwitterDemoPortrait"
        component={KernDemoVideo}
        durationInFrames={durationInFrames}
        fps={fps}
        width={1080}
        height={1350}
        defaultProps={{layout: 'portrait'}}
      />
    </>
  );
};
