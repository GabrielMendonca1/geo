import React, { useCallback, useEffect, useRef, useState } from 'react';
import { Box, useApp, useInput, useStdout } from 'ink';
import { Header } from './Header.js';
import { MessageLine, type Message } from './Conversation.js';
import { GeoSpinner } from './Spinner.js';
import { Input } from './Input.js';
import { useStatusFile } from './useStatusFile.js';

type Props = {
  runTurn: (text: string) => Promise<string>;
  statusFilePath: string;
};

function makeId(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

function greetingSalutation(date: Date): string {
  const h = date.getHours();
  if (h < 5) return 'boa madrugada';
  if (h < 12) return 'bom dia';
  if (h < 18) return 'boa tarde';
  return 'boa noite';
}

const PT_WEEKDAY = ['dom', 'seg', 'ter', 'qua', 'qui', 'sex', 'sáb'];

function greetingDateLine(date: Date): string {
  const wd = PT_WEEKDAY[date.getDay()];
  const dd = date.getDate().toString().padStart(2, '0');
  const mm = (date.getMonth() + 1).toString().padStart(2, '0');
  return `${wd} ${dd}/${mm}`;
}

function makeGreeting(now: Date): Message {
  const body = [
    `${greetingSalutation(now)}, daddy.`,
    greetingDateLine(now) + '.',
    '',
    'try',
    '  como tá o meu dia?',
    '  log: <pensamento>',
    '  o que escrevi sobre X?',
  ].join('\n');
  return { id: 'greeting', role: 'geo', text: body, timestamp: now, dim: true };
}

const HELP_TEXT = [
  'commands',
  '  /clear   — clear conversation',
  '  /help    — show this',
  '',
  'shortcuts',
  '  ↑ ↓      — recall previous messages',
  '  ctrl+c   — exit',
  '  ctrl+l   — clear conversation',
  '  esc      — cancel an inflight reply',
].join('\n');

export function App({ runTurn, statusFilePath }: Props): React.ReactElement {
  const { exit } = useApp();
  const { stdout } = useStdout();
  const [rows, setRows] = useState<number>(() => stdout?.rows ?? 24);

  useEffect(() => {
    if (!stdout) return;
    const onResize = (): void => setRows(stdout.rows ?? 24);
    stdout.on('resize', onResize);
    return () => {
      stdout.off('resize', onResize);
    };
  }, [stdout]);

  const PAGE = Math.max(3, Math.floor(Math.max(rows - 6, 1) / 5));
  const SCROLL_STEP = Math.max(1, Math.floor(PAGE / 2));
  const status = useStatusFile(statusFilePath);
  const [messages, setMessages] = useState<Message[]>(() => [makeGreeting(new Date())]);
  const [inflight, setInflight] = useState(false);
  const [scrollOffset, setScrollOffset] = useState(0);
  const turnIdRef = useRef(0);
  const userHistoryRef = useRef<string[]>([]);

  const inflightRef = useRef(false);
  const messagesLenRef = useRef(messages.length);
  const pageRef = useRef(PAGE);
  const scrollStepRef = useRef(SCROLL_STEP);
  useEffect(() => { inflightRef.current = inflight; }, [inflight]);
  useEffect(() => { messagesLenRef.current = messages.length; }, [messages.length]);
  useEffect(() => { pageRef.current = PAGE; }, [PAGE]);
  useEffect(() => { scrollStepRef.current = SCROLL_STEP; }, [SCROLL_STEP]);

  const append = useCallback((msg: Message): void => {
    setMessages((prev) => [...prev, msg]);
  }, []);

  const submit = useCallback(
    (text: string): void => {
      if (inflightRef.current) return;
      userHistoryRef.current.push(text);

      setScrollOffset(0);

      if (text.startsWith('/')) {
        const cmd = text.slice(1).trim().toLowerCase();
        if (cmd === 'clear') {
          setMessages([]);
          return;
        }
        if (cmd === 'help' || cmd === '?') {
          append({ id: makeId(), role: 'geo', text: HELP_TEXT, timestamp: new Date(), dim: true });
          return;
        }
        append({
          id: makeId(),
          role: 'geo',
          text: `unknown command: /${cmd}. try /help.`,
          timestamp: new Date(),
          dim: true,
        });
        return;
      }

      append({ id: makeId(), role: 'you', text, timestamp: new Date() });
      setInflight(true);
      const turnId = ++turnIdRef.current;
      runTurn(text)
        .then((reply) => {
          if (turnIdRef.current !== turnId) return;
          append({ id: makeId(), role: 'geo', text: reply || '(no reply)', timestamp: new Date() });
          setInflight(false);
        })
        .catch((err: unknown) => {
          if (turnIdRef.current !== turnId) return;
          const msg = err instanceof Error ? err.message : String(err);
          append({
            id: makeId(),
            role: 'geo',
            text: `something went wrong: ${msg}`,
            timestamp: new Date(),
            error: true,
          });
          setInflight(false);
        });
    },
    [append, runTurn],
  );

  useInput(
    (_input, key) => {
      if (key.ctrl && _input === 'c') {
        exit();
        return;
      }
      if (key.ctrl && _input === 'l') {
        setMessages([]);
        setScrollOffset(0);
        return;
      }
      const len = messagesLenRef.current;
      const page = pageRef.current;
      const step = scrollStepRef.current;
      const maxOffset = Math.max(0, len - page);

      if (key.pageUp || (key.ctrl && _input === 'u')) {
        setScrollOffset((o) => Math.min(o + step, maxOffset));
        return;
      }
      if (key.pageDown || (key.ctrl && _input === 'd')) {
        setScrollOffset((o) => Math.max(0, o - step));
        return;
      }
      if (key.ctrl && _input === 'b') {
        setScrollOffset((o) => Math.min(o + page, maxOffset));
        return;
      }
      if (key.ctrl && _input === 'f') {
        setScrollOffset((o) => Math.max(0, o - page));
        return;
      }
      if (key.ctrl && _input === 'e') {
        setScrollOffset(0);
        return;
      }
      if (key.escape) {
        if (inflightRef.current) {
          turnIdRef.current += 1;
          setInflight(false);
          append({ id: makeId(), role: 'geo', text: '(canceled)', timestamp: new Date(), dim: true });
        }
      }
    },
    { isActive: process.stdin.isTTY === true },
  );

  const end = Math.min(messages.length, Math.max(0, messages.length - scrollOffset));
  const start = Math.max(0, end - PAGE);
  const visibleMessages = messages.slice(start, end);
  const scrolledBack = scrollOffset > 0;

  return (
    <Box flexDirection="column" height={rows}>
      <Box flexDirection="column" flexGrow={1} justifyContent="flex-end" overflow="hidden">
        {visibleMessages.map((m) => (
          <MessageLine key={m.id} message={m} />
        ))}
        {inflight && !scrolledBack ? <GeoSpinner /> : null}
      </Box>
      <Header status={status} scrolledBack={scrolledBack} />
      <Input disabled={inflight} onSubmit={submit} history={userHistoryRef.current} />
    </Box>
  );
}
