import React, { useEffect, useState } from 'react';
import { Box, Text } from 'ink';

const PERIOD_MS = 1200;
const STEP_MS = 80;

export function ThinkingDot(): React.ReactElement {
  const [phase, setPhase] = useState(0);

  useEffect(() => {
    const start = Date.now();
    const id = setInterval(() => {
      const elapsed = (Date.now() - start) % PERIOD_MS;
      setPhase(elapsed / PERIOD_MS);
    }, STEP_MS);
    return () => clearInterval(id);
  }, []);

  const intensity = (Math.sin(phase * Math.PI * 2) + 1) / 2;
  const bright = intensity > 0.55;

  return (
    <Box paddingX={2} paddingY={1}>
      <Text color="cyan" dimColor>geo</Text>
      <Text>  </Text>
      <Text color="cyan" dimColor={!bright}>●</Text>
    </Box>
  );
}
