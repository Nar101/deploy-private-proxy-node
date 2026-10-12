#!/usr/bin/env python3
"""Stream a debug log with credential and handshake material removed."""
import json
import re
import sys


def collect_secrets(value, key='', result=None):
    if result is None:
        result = set()
    if isinstance(value, dict):
        for child_key, child in value.items():
            collect_secrets(child, str(child_key), result)
    elif isinstance(value, list):
        for child in value:
            collect_secrets(child, key, result)
    elif isinstance(value, str) and any(m in key.lower() for m in ('id', 'key', 'password', 'token', 'secret')):
        if len(value) >= 2:
            result.add(value)
    return result


UUID = re.compile(r'(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b')
URI = re.compile(r'(?i)\b(?:vless|vmess|trojan|ss|ssr)://[^\s\"<>]+')
LABEL = re.compile(
    r'''(?ix)(["']?(?:short[._-]?ids?|private[._-]?key|public[._-]?key|password|passwd|uuid|token|secret|authkey|session[._-]?id|client[._-]?random|server[._-]?random|random|client[._-]?hello|key[._-]?shares?|plaintext|ciphertext|pbk|sid)(?:\[[^\]]*\])?["']?\s*[:=]\s*)(\[[^\]\n]*\]|\{[^}\n]*\}|"[^"\n]*"|'[^'\n]*'|[^\s,;}]+)'''
)
PRIVATE_BEGIN = re.compile(r'-----BEGIN .*PRIVATE KEY-----')
PRIVATE_END = re.compile(r'-----END .*PRIVATE KEY-----')


def redact_line(line, secrets=()):
    line = URI.sub('[NODE_URI_REDACTED]', line)
    line = UUID.sub('[UUID_REDACTED]', line)
    line = LABEL.sub(lambda m: m.group(1) + '[REDACTED]', line)
    for secret in secrets:
        line = line.replace(secret, '[REDACTED]')
    return line


class Redactor:
    def __init__(self, config=None):
        self.secrets = sorted(collect_secrets(config or {}), key=len, reverse=True)
        self.private_block = False

    def line(self, value):
        if PRIVATE_BEGIN.search(value):
            self.private_block = True
            return '[PRIVATE_KEY_BLOCK_REDACTED]\n'
        if self.private_block:
            if PRIVATE_END.search(value):
                self.private_block = False
            return ''
        return redact_line(value, self.secrets)


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: redact-debug-log.py <effective-config.json|->')
    config = None
    if sys.argv[1] != '-':
        try:
            with open(sys.argv[1], encoding='utf-8') as fh:
                config = json.load(fh)
        except (OSError, ValueError):
            raise SystemExit('FAIL redaction_config=unreadable_or_invalid')
    redactor = Redactor(config)
    for line in sys.stdin:
        sys.stdout.write(redactor.line(line))
        sys.stdout.flush()


if __name__ == '__main__':
    main()
