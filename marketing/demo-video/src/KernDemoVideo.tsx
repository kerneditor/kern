import React from 'react';
import {
  AbsoluteFill,
  Img,
  OffthreadVideo,
  interpolate,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';

type Layout = 'landscape' | 'portrait';

type KernDemoVideoProps = {
  layout: Layout;
};

const blue = '#0A84FF';
const white = '#F7FBFF';
const muted = '#B9C6D8';
const line = 'rgba(255,255,255,0.16)';
const fps = 30;

const asset = (name: string) => staticFile(`generated/${name}`);

const featureBeats = [
  {
    start: 0,
    end: 5.2,
    eyebrow: 'True WYSIWYG Markdown',
    title: 'Edit the rendered document.',
    body: 'The Markdown file opens as real styled text — headings, emphasis, code, quotes, tables, and tasks are already rendered.',
  },
  {
    start: 5.2,
    end: 10.2,
    eyebrow: 'Built on TextKit',
    title: 'Native editing primitives.',
    body: 'Selection, typing, scrolling, layout, and text rendering come from macOS-native text infrastructure — not a browser editor.',
  },
  {
    start: 10.2,
    end: 15.4,
    eyebrow: 'No web shell',
    title: 'No Electron.\nNo Tauri.\nNo WebView.',
    body: 'Kern is a fully native macOS app, built with Swift, AppKit, and TextKit instead of embedding a web runtime.',
  },
  {
    start: 15.4,
    end: 20.1,
    eyebrow: 'Plain Markdown on disk',
    title: 'Portable files, native feel.',
    body: 'You keep normal .md files while editing them like a document instead of staring at Markdown punctuation.',
  },
  {
    start: 20.1,
    end: 24.0,
    eyebrow: 'Open source macOS editor',
    title: 'Kern is for local writing.',
    body: 'A Mac-first Markdown editor focused on speed, fidelity, and direct manipulation.',
  },
];

const techPills = ['Swift', 'AppKit', 'TextKit', 'No Electron', 'No Tauri', 'No WebView'];

export const KernDemoVideo: React.FC<KernDemoVideoProps> = ({layout}) => {
  const frame = useCurrentFrame();
  const {width, height} = useVideoConfig();
  const isPortrait = layout === 'portrait';
  const seconds = frame / fps;
  const beat = currentBeat(seconds);
  const beatIndex = featureBeats.indexOf(beat);

  return (
    <AbsoluteFill style={{backgroundColor: '#05070d', color: white, fontFamily: fontStack()}}>
      <LiveVideoBackground />
      <GridGlow />
      {isPortrait ? (
        <PortraitLayout beat={beat} beatIndex={beatIndex} />
      ) : (
        <LandscapeLayout beat={beat} beatIndex={beatIndex} />
      )}
      <ProgressBar frame={frame} total={24 * fps} width={width} height={height} />
    </AbsoluteFill>
  );
};

const LandscapeLayout: React.FC<{beat: Beat; beatIndex: number}> = ({beat, beatIndex}) => {
  const frame = useCurrentFrame();
  const {fps: videoFps} = useVideoConfig();
  const enter = spring({frame, fps: videoFps, config: {damping: 120, stiffness: 160}});

  return (
    <AbsoluteFill style={{padding: 58}}>
      <div
        style={{
          position: 'absolute',
          left: 70,
          top: 66,
          width: 510,
          height: 948,
          display: 'flex',
          flexDirection: 'column',
          justifyContent: 'space-between',
        }}
      >
        <div>
          <BrandHeader compact={false} />
          <BeatCopy beat={beat} beatIndex={beatIndex} compact={false} />
        </div>
        <div>
          <TechStack />
          <BottomClaim />
        </div>
      </div>
      <MacRecordingFrame
        style={{
          position: 'absolute',
          right: 56,
          top: 56,
          width: 1280,
          height: 886,
          transform: `translateY(${(1 - enter) * 26}px) scale(${0.985 + enter * 0.015})`,
        }}
      />
      <NativeCallout style={{right: 82, bottom: 68}} />
    </AbsoluteFill>
  );
};

const PortraitLayout: React.FC<{beat: Beat; beatIndex: number}> = ({beat, beatIndex}) => {
  const frame = useCurrentFrame();
  const {fps: videoFps} = useVideoConfig();
  const enter = spring({frame, fps: videoFps, config: {damping: 120, stiffness: 160}});

  return (
    <AbsoluteFill style={{padding: 54}}>
      <div style={{position: 'absolute', left: 58, top: 64, right: 58}}>
        <BrandHeader compact />
      </div>
      <MacRecordingFrame
        style={{
          position: 'absolute',
          left: 50,
          top: 280,
          width: 980,
          height: 678,
          transform: `translateY(${(1 - enter) * 26}px) scale(${0.985 + enter * 0.015})`,
        }}
      />
      <div style={{position: 'absolute', left: 64, right: 64, top: 1000}}>
        <BeatCopy beat={beat} beatIndex={beatIndex} compact />
      </div>
      <div style={{position: 'absolute', left: 64, right: 64, bottom: 70}}>
        <TechStack compact />
      </div>
    </AbsoluteFill>
  );
};

type Beat = (typeof featureBeats)[number];

const currentBeat = (seconds: number): Beat =>
  featureBeats.find((beat) => seconds >= beat.start && seconds < beat.end) ?? featureBeats[featureBeats.length - 1];

const fontStack = () =>
  '-apple-system, BlinkMacSystemFont, "SF Pro Display", "Inter", "Helvetica Neue", Arial, sans-serif';

const BrandHeader: React.FC<{compact: boolean}> = ({compact}) => {
  const frame = useCurrentFrame();
  const {fps: videoFps} = useVideoConfig();
  const scale = spring({frame, fps: videoFps, config: {damping: 120, stiffness: 160}});

  return (
    <div style={{display: 'flex', alignItems: 'center', gap: compact ? 20 : 24, transform: `scale(${0.985 + scale * 0.015})`, transformOrigin: 'left center'}}>
      <IconTile size={compact ? 82 : 94} />
      <div>
        <div style={{fontSize: compact ? 64 : 72, fontWeight: 900, letterSpacing: compact ? -3.2 : -3.8, lineHeight: 0.9}}>Kern</div>
        <div style={{marginTop: compact ? 7 : 10, color: muted, fontSize: compact ? 25 : 28, fontWeight: 720}}>
          Native WYSIWYG Markdown
        </div>
      </div>
    </div>
  );
};

const BeatCopy: React.FC<{beat: Beat; beatIndex: number; compact: boolean}> = ({beat, beatIndex, compact}) => {
  const frame = useCurrentFrame();
  const seconds = frame / fps;
  const multiline = beat.title.includes('\n');
  const local = Math.max(0, seconds - beat.start);
  const opacity = interpolate(local, [0, 0.22, Math.max(0.28, beat.end - beat.start - 0.35), beat.end - beat.start], [0, 1, 1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const y = interpolate(local, [0, 0.28], [18, 0], {extrapolateRight: 'clamp'});

  return (
    <div key={beatIndex} style={{opacity, transform: `translateY(${y}px)`, marginTop: compact ? 0 : 72}}>
      <Eyebrow compact={compact}>{beat.eyebrow}</Eyebrow>
      <div
        style={{
          marginTop: compact ? 13 : 18,
          fontSize: compact ? (multiline ? 43 : 56) : 67,
          lineHeight: compact ? (multiline ? 0.91 : 0.96) : 0.94,
          letterSpacing: compact ? -2.8 : -3.5,
          fontWeight: 900,
          whiteSpace: 'pre-line',
        }}
      >
        {beat.title}
      </div>
      <div
        style={{
          marginTop: compact ? (multiline ? 12 : 18) : 24,
          fontSize: compact ? (multiline ? 23 : 27) : 30,
          lineHeight: 1.2,
          color: '#D6E1F2',
          fontWeight: 640,
        }}
      >
        {beat.body}
      </div>
    </div>
  );
};

const TechStack: React.FC<{compact?: boolean}> = ({compact = false}) => {
  return (
    <div>
      <div style={{color: '#8fc5ff', fontSize: compact ? 21 : 22, fontWeight: 850, letterSpacing: 1.7, textTransform: 'uppercase'}}>
        Built different
      </div>
      <div style={{display: 'flex', flexWrap: 'wrap', gap: compact ? 10 : 12, marginTop: compact ? 15 : 18}}>
        {techPills.map((pill, index) => (
          <Pill key={pill} delay={index * 5} compact={compact} important={pill.startsWith('No ') || pill === 'TextKit'}>
            {pill}
          </Pill>
        ))}
      </div>
    </div>
  );
};

const BottomClaim: React.FC = () => (
  <div
    style={{
      marginTop: 34,
      padding: '22px 24px',
      borderRadius: 26,
      background: 'rgba(10,132,255,0.13)',
      border: '1px solid rgba(143,197,255,0.30)',
      color: '#ECF6FF',
      fontSize: 25,
      lineHeight: 1.18,
      fontWeight: 760,
      boxShadow: '0 24px 70px rgba(10,132,255,0.13)',
    }}
  >
    Local files. Plain Markdown. Native Mac app.
  </div>
);

const MacRecordingFrame: React.FC<{style: React.CSSProperties}> = ({style}) => (
  <div
    style={{
      borderRadius: 30,
      overflow: 'hidden',
      background: '#15181f',
      boxShadow: '0 44px 120px rgba(0,0,0,0.48), 0 0 0 1px rgba(255,255,255,0.16)',
      ...style,
    }}
  >
    <div
      style={{
        height: 46,
        display: 'flex',
        alignItems: 'center',
        padding: '0 18px',
        gap: 9,
        background: 'linear-gradient(180deg, rgba(255,255,255,0.10), rgba(255,255,255,0.045))',
        borderBottom: '1px solid rgba(255,255,255,0.08)',
      }}
    >
      <Traffic color="#ff5f57" />
      <Traffic color="#febc2e" />
      <Traffic color="#28c840" />
      <div style={{marginLeft: 16, color: '#C9D4E6', fontSize: 18, fontWeight: 760}}>Actual Kern recording</div>
    </div>
    <div style={{position: 'absolute', left: 0, right: 0, bottom: 0, top: 46, overflow: 'hidden'}}>
      <OffthreadVideo
        src={asset('kern-live-wysiwyg-recording.mp4')}
        muted
        style={{width: '100%', height: '100%', objectFit: 'cover'}}
      />
    </div>
  </div>
);

const LiveVideoBackground: React.FC = () => (
  <AbsoluteFill style={{overflow: 'hidden'}}>
    <OffthreadVideo
      src={asset('kern-live-wysiwyg-recording.mp4')}
      muted
      style={{
        width: '100%',
        height: '100%',
        objectFit: 'cover',
        filter: 'blur(30px) brightness(0.30) saturate(1.1)',
        transform: 'scale(1.12)',
        opacity: 0.72,
      }}
    />
    <AbsoluteFill style={{background: 'linear-gradient(100deg, rgba(5,7,13,0.98) 0%, rgba(5,7,13,0.76) 44%, rgba(5,7,13,0.48) 100%)'}} />
  </AbsoluteFill>
);

const GridGlow: React.FC = () => (
  <AbsoluteFill
    style={{
      background:
        'radial-gradient(circle at 18% 16%, rgba(10,132,255,0.35), transparent 25%), radial-gradient(circle at 86% 80%, rgba(88,166,255,0.16), transparent 28%), linear-gradient(rgba(255,255,255,0.035) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.035) 1px, transparent 1px)',
      backgroundSize: 'auto, auto, 48px 48px, 48px 48px',
      opacity: 0.7,
    }}
  />
);

const NativeCallout: React.FC<{style: React.CSSProperties}> = ({style}) => (
  <div
    style={{
      position: 'absolute',
      padding: '15px 18px',
      borderRadius: 999,
      background: 'rgba(2,6,23,0.74)',
      border: `1px solid ${line}`,
      color: '#EFF7FF',
      fontSize: 23,
      fontWeight: 850,
      backdropFilter: 'blur(16px)',
      boxShadow: '0 20px 70px rgba(0,0,0,0.38)',
      ...style,
    }}
  >
    Swift + AppKit + TextKit · no browser engine
  </div>
);

const Pill: React.FC<{children: React.ReactNode; delay?: number; compact?: boolean; important?: boolean}> = ({
  children,
  delay = 0,
  compact = false,
  important = false,
}) => {
  const frame = useCurrentFrame();
  const opacity = interpolate(frame, [delay, delay + 12], [0, 1], {extrapolateRight: 'clamp'});
  const y = interpolate(frame, [delay, delay + 12], [10, 0], {extrapolateRight: 'clamp'});
  return (
    <div
      style={{
        opacity,
        transform: `translateY(${y}px)`,
        padding: compact ? '10px 13px' : '11px 15px',
        borderRadius: 999,
        background: important ? 'rgba(10,132,255,0.18)' : 'rgba(255,255,255,0.09)',
        border: important ? '1px solid rgba(143,197,255,0.36)' : `1px solid ${line}`,
        color: '#F1F7FF',
        fontSize: compact ? 20 : 21,
        fontWeight: 820,
      }}
    >
      {children}
    </div>
  );
};

const Eyebrow: React.FC<{children: React.ReactNode; compact?: boolean}> = ({children, compact = false}) => (
  <div style={{color: '#8fc5ff', textTransform: 'uppercase', letterSpacing: compact ? 2 : 2.2, fontSize: compact ? 20 : 22, fontWeight: 900}}>
    {children}
  </div>
);

const IconTile: React.FC<{size: number}> = ({size}) => (
  <div
    style={{
      width: size,
      height: size,
      borderRadius: Math.round(size * 0.22),
      overflow: 'hidden',
      boxShadow: '0 24px 60px rgba(10,132,255,0.28), 0 0 0 1px rgba(255,255,255,0.22)',
      flex: '0 0 auto',
    }}
  >
    <Img src={asset('kern-icon.png')} style={{width: '100%', height: '100%'}} />
  </div>
);

const Traffic: React.FC<{color: string}> = ({color}) => (
  <div style={{width: 14, height: 14, borderRadius: 999, background: color, boxShadow: 'inset 0 0 0 1px rgba(0,0,0,0.18)'}} />
);

const ProgressBar: React.FC<{frame: number; total: number; width: number; height: number}> = ({frame, total, width, height}) => {
  const progress = Math.min(1, frame / total);
  return (
    <div
      style={{
        position: 'absolute',
        left: 0,
        bottom: 0,
        width: width * progress,
        height: Math.max(5, Math.round(height * 0.006)),
        background: `linear-gradient(90deg, ${blue}, #72d6ff)`,
      }}
    />
  );
};
