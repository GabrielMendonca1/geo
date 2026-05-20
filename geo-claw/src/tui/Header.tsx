import React, { useEffect, useState } from 'react';
import { Box, Text } from 'ink';
import type { ConnectorUiState, StatusSnapshot } from './useStatusFile.js';

const ACCENT = 'cyan';

function colorFor(state: ConnectorUiState): string {
  switch (state) {
    case 'connected':
      return ACCENT;
    case 'connecting':
      return 'yellow';
    case 'error':
      return 'red';
    default:
      return 'gray';
  }
}

type DotProps = { state: ConnectorUiState };

function StatusDot({ state }: DotProps): React.ReactElement {
  const target = colorFor(state);
  const [color, setColor] = useState<string>(target);
  const [previous, setPrevious] = useState<string>(target);

  useEffect(() => {
    if (target === color) return;
    setPrevious(color);
    setColor('white');
    const t = setTimeout(() => {
      setColor(target);
    }, 200);
    return () => clearTimeout(t);
  }, [target]);

  void previous;
  return <Text color={color}>●</Text>;
}

type Props = { status: StatusSnapshot };

export function Header({ status }: Props): React.ReactElement {
  const mcpState: ConnectorUiState = status.mcpConnected ? 'connected' : 'disconnected';
  return (
    <Box flexDirection="column" paddingX={2} paddingTop={1} paddingBottom={1}>
      <Text color={ACCENT}>geo</Text>
      <Box marginTop={1}>
        <StatusDot state={mcpState} />
        <Text dimColor> mcp </Text>
        <Text dimColor>· </Text>
        <StatusDot state={status.whatsapp} />
        <Text dimColor> whatsapp </Text>
        <Text dimColor>· </Text>
        <StatusDot state={status.gmail} />
        <Text dimColor> gmail </Text>
        <Text dimColor>· </Text>
        <StatusDot state={status.telegram} />
        <Text dimColor> telegram </Text>
        <Text dimColor>· {status.cronsCount} crons</Text>
      </Box>
    </Box>
  );
}
