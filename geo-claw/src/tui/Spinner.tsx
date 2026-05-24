import React, { useEffect, useRef, useState } from 'react';
import { Box, Text } from 'ink';
import { COLORS, GLYPHS, VERBS_PT } from './theme.js';

const FRAME_MS = 80;
const VERB_PERIOD_MS = 2500;
const VERB_WIDTH = Math.max(...VERBS_PT.map((v) => v.length));

function padVerb(v: string): string {
  return v + ' '.repeat(Math.max(0, VERB_WIDTH - v.length));
}

export function GeoSpinner(): React.ReactElement {
  const startRef = useRef<number>(Date.now());
  const [, force] = useState(0);

  useEffect(() => {
    const id = setInterval(() => force((n) => n + 1), FRAME_MS);
    return () => clearInterval(id);
  }, []);

  const elapsed = Date.now() - startRef.current;
  const frame = Math.floor(elapsed / FRAME_MS) % GLYPHS.spinner.length;
  const verbIdx = Math.floor(elapsed / VERB_PERIOD_MS) % VERBS_PT.length;

  return (
    <Box paddingX={2} marginBottom={1}>
      <Text color={COLORS.accent}>{GLYPHS.spinner[frame]} </Text>
      <Text dimColor>{padVerb(VERBS_PT[verbIdx] ?? '')}…</Text>
    </Box>
  );
}
