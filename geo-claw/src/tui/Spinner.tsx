import React, { useEffect, useRef, useState } from 'react';
import { Box, Text } from 'ink';
import { COLORS, GLYPHS, VERBS_PT } from './theme.js';

const FRAME_MS = 120;
const VERB_MS = 1800;

export function GeoSpinner(): React.ReactElement {
  const [frame, setFrame] = useState(0);
  const verbStartRef = useRef<number>(Math.floor(Math.random() * VERBS_PT.length));
  const [verbIdx, setVerbIdx] = useState(verbStartRef.current);

  useEffect(() => {
    const id = setInterval(() => {
      setFrame((f) => (f + 1) % GLYPHS.spinner.length);
    }, FRAME_MS);
    return () => clearInterval(id);
  }, []);

  useEffect(() => {
    const id = setInterval(() => {
      setVerbIdx((i) => (i + 1) % VERBS_PT.length);
    }, VERB_MS);
    return () => clearInterval(id);
  }, []);

  return (
    <Box paddingX={2} marginBottom={1}>
      <Text color={COLORS.accent}>{GLYPHS.spinner[frame]} </Text>
      <Text dimColor>{VERBS_PT[verbIdx]}…</Text>
    </Box>
  );
}
