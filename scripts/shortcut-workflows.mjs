import { randomUUID } from 'node:crypto';

// Images are downloaded WITH the shortcut and stored in its workflow on the iPhone.
// No network, iCloud file, server URL or shared mutable image is read at notification time.
export const SHORTCUTS = [
  { id: 'earthquake', title: 'Nigeyo 地震', triggerTitle: 'EARTHQUAKE_TEST' },
  { id: 'tsunami', title: 'Nigeyo 津波', triggerTitle: 'TSUNAMI_TEST' },
];

const output = (id, name) => ({ Value: { OutputUUID: id, Type: 'ActionOutput', OutputName: name }, WFSerializationType: 'WFTextTokenAttachment' });

// Format observed in a macOS 27 Shortcuts UI export on 2026-10-25.
// Operator 0 is the notification Title "contains" filter (not a generic If operator).
// No personal signing team or local picker identity from that export is distributed.
export function notificationTrigger(triggerTitle, bundleIdentifier = 'jp.nigeyo.hackathon') {
  if (!SHORTCUTS.some((s) => s.triggerTitle === triggerTitle)) throw new Error('unsupported-notification-title');
  if (!/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/.test(bundleIdentifier)) throw new Error('invalid-app-bundle-id');
  return {
    WFTriggerIdentifier: 'WFNotificationTrigger',
    WFTriggerUUID: randomUUID().toUpperCase(),
    WFTriggerSerializedParameters: {
      Conditions: {
        WFSerializationType: 'WFContentPredicateTableTemplate',
        Value: {
          WFActionParameterFilterTemplates: [{ Property: 'Title', Operator: 0, Values: { Title: triggerTitle }, Removable: true }],
          WFContentPredicateBoundedDate: false,
          WFActionParameterFilterPrefix: 1,
        },
      },
      SelectedApps: { BundleIdentifier: bundleIdentifier, Name: 'Nigeyo' },
    },
  };
}

export function workflow(png, { triggerTitle, bundleIdentifier } = {}) {
  const textId = '4F1D3A52-0E1B-4C1C-9B7A-2D6E8F1A0001';
  const decodeId = '4F1D3A52-0E1B-4C1C-9B7A-2D6E8F1A0002';
  const imageId = '4F1D3A52-0E1B-4C1C-9B7A-2D6E8F1A0003';
  return {
    WFWorkflowMinimumClientVersion: 900,
    WFWorkflowMinimumClientVersionString: '900',
    WFWorkflowClientVersion: '5037.111',
    WFWorkflowTriggers: [notificationTrigger(triggerTitle, bundleIdentifier)],
    WFWorkflowIcon: { WFWorkflowIconStartColor: 4282601983, WFWorkflowIconGlyphNumber: 59511 },
    WFWorkflowTypes: [], WFWorkflowInputContentItemClasses: [],
    WFWorkflowHasShortcutInputVariables: false, WFWorkflowImportQuestions: [],
    WFWorkflowActions: [
      { WFWorkflowActionIdentifier: 'is.workflow.actions.gettext', WFWorkflowActionParameters: { WFTextActionText: png.toString('base64'), UUID: textId } },
      { WFWorkflowActionIdentifier: 'is.workflow.actions.base64encode', WFWorkflowActionParameters: { WFInput: output(textId, 'Text'), WFEncodeMode: 'Decode', UUID: decodeId } },
      { WFWorkflowActionIdentifier: 'is.workflow.actions.detect.images', WFWorkflowActionParameters: { WFInput: output(decodeId, 'Base64 Encoded'), UUID: imageId } },
      { WFWorkflowActionIdentifier: 'is.workflow.actions.wallpaper.set', WFWorkflowActionParameters: {
        WFInput: output(imageId, 'Images'), WFWallpaperShowPreview: false, WFWallpaperLocation: 'Lock Screen' } },
      { WFWorkflowActionIdentifier: 'is.workflow.actions.openurl', WFWorkflowActionParameters: { WFInput: 'nigeyo://guide' } },
    ],
  };
}

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
export function plistValue(v) {
  if (typeof v === 'boolean') return v ? '<true/>' : '<false/>';
  if (typeof v === 'number') return Number.isInteger(v) ? `<integer>${v}</integer>` : `<real>${v}</real>`;
  if (typeof v === 'string') return `<string>${esc(v)}</string>`;
  if (Array.isArray(v)) return `<array>${v.map(plistValue).join('')}</array>`;
  return `<dict>${Object.entries(v).map(([k, x]) => `<key>${esc(k)}</key>${plistValue(x)}`).join('')}</dict>`;
}
