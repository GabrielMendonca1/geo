import React, { useEffect, useState } from 'react';
import { Box, Text } from 'ink';
import type { ConnectorUiState, StatusSnapshot } from './useStatusFile.js';

function colorFor(state: ConnectorUiState): string {
  switch (state) {
    case 'connected':
      return 'green';
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

  useEffect(() => {
    if (target === color) return;
    setColor('white');
    const t = setTimeout(() => setColor(target), 200);
    return () => clearTimeout(t);
  }, [target]);

  return <Text color={color}>●</Text>;
}

type Props = { status: StatusSnapshot };

export function Header({ status }: Props): React.ReactElement {
  const mcpState: ConnectorUiState = status.mcpConnected ? 'connected' : 'disconnected';
  return (
    <Box paddingX={2}>
      <StatusDot state={mcpState} />
      <Text dimColor> mcp</Text>
      <Text dimColor> · </Text>
      <StatusDot state={status.whatsapp} />
      <Text dimColor> wa</Text>
      <Text dimColor> · </Text>
      <StatusDot state={status.gmail} />
      <Text dimColor> gm</Text>
      <Text dimColor> · </Text>
      <StatusDot state={status.telegram} />
      <Text dimColor> tg</Text>
      <Text dimColor> · </Text>
      <Text dimColor>{status.cronsCount} crons</Text>
      {scrolledBack ? (
        <>
          <Text dimColor>   </Text>
          <Text color="yellow">↑ scrolled</Text>
        </>
      ) : null}
    </Box>
  );
}
