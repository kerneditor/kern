import {copyFileSync, mkdirSync, existsSync} from 'node:fs';
import {resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, '..');
const repo = resolve(project, '../..');
const out = resolve(project, 'public/generated');

const assets = [
  ['KernApp/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png', 'kern-icon.png'],
  ['dist/social/kern-live-wysiwyg-recording.mp4', 'kern-live-wysiwyg-recording.mp4'],
  ['KernTests/__Snapshots__/NativeEditorSnapshotTests/testBasicFixture_GfmDefault_Light.1.png', 'editor-default.png'],
  ['KernTests/__Snapshots__/NativeEditorSnapshotTests/testSnapshotMatrix_Exhaustive.gfmDefault_task-permutations-fixture-md_light_lg.png', 'editor-checklists.png'],
  ['test-fixtures/screenshots/10-mermaid-direct-render.png', 'editor-mermaid.png'],
  ['test-fixtures/screenshots/11-code-languages-cjk.png', 'editor-international.png'],
  ['KernTests/__Snapshots__/NativeEditorSnapshotTests/testSnapshotMatrix_Exhaustive.gfmDefault_code-chrome-fixture-md_dark_lg.png', 'editor-code-dark.png'],
  ['KernTests/__Snapshots__/NativeEditorSnapshotTests/testThemeAndFontPresetSnapshots.theme-githubDark-font-inter.png', 'theme-dark.png'],
  ['KernTests/__Snapshots__/NativeEditorSnapshotTests/testThemeAndFontPresetSnapshots.theme-solarizedLight-font-sourceSerif.png', 'theme-light.png']
];

mkdirSync(out, {recursive: true});
for (const [source, target] of assets) {
  const src = resolve(repo, source);
  if (!existsSync(src)) {
    throw new Error(`Missing source asset: ${source}`);
  }
  copyFileSync(src, resolve(out, target));
}

console.log(`Prepared ${assets.length} assets in public/generated`);
