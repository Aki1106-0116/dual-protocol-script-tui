#!/usr/bin/env python3
"""Parse Xray X25519 keys and verify their relationship with OpenSSL."""
import base64
import hmac
import re
import subprocess
import sys

PRIVATE_PREFIX = bytes.fromhex('302e020100300506032b656e04220420')
PUBLIC_PREFIX = bytes.fromhex('302a300506032b656e032100')

def decode(value):
    if not re.fullmatch(r'[A-Za-z0-9_-]{43}={0,1}', value):
        raise ValueError('REALITY 密钥字符或长度异常')
    raw = base64.b64decode(value.rstrip('=')+'=', altchars=b'-_', validate=True)
    if len(raw) != 32:
        raise ValueError('REALITY 密钥必须为 32 字节')
    return raw

def parse(output):
    pair = {}
    for line in output.splitlines():
        label, separator, value = line.partition(':')
        if not separator:
            continue
        label = re.sub('[^a-z0-9]', '', label.lower())
        if label in ('privatekey', 'private', 'privkey'):
            name = 'private'
        elif label in ('publickey', 'public', 'pubkey', 'password', 'passwordpublickey') or ('publickey' in label and 'hash' not in label):
            name = 'public'
        else:
            continue
        if name in pair and pair[name] != value.strip():
            raise ValueError('Xray 输出了相互冲突的密钥字段')
        pair[name] = value.strip()
    if set(pair) != {'private', 'public'}:
        raise ValueError('Xray 未返回完整 REALITY 密钥对')
    private, public = decode(pair['private']), decode(pair['public'])
    result = subprocess.run(['openssl', 'pkey', '-inform', 'DER', '-pubout', '-outform', 'DER'],
                            input=PRIVATE_PREFIX+private, capture_output=True, timeout=10)
    if result.returncode or len(result.stdout) != len(PUBLIC_PREFIX)+32 or not result.stdout.startswith(PUBLIC_PREFIX):
        raise ValueError('OpenSSL 无法验证 X25519 密钥')
    if not hmac.compare_digest(result.stdout[len(PUBLIC_PREFIX):], public):
        raise ValueError('REALITY 公私钥不匹配，拒绝修改原密钥')
    return pair

def main():
    result = subprocess.run([sys.argv[1], 'x25519'], capture_output=True, timeout=15)
    if result.returncode:
        raise ValueError('Xray 密钥生成失败；不回显可能包含私钥的输出')
    pair = parse(result.stdout.decode())
    print('PRIVATE='+pair['private'])
    print('PUBLIC='+pair['public'])

if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('REALITY 密钥生成/验证失败，旧密钥未修改；请检查 Xray 与 OpenSSL 版本。', file=sys.stderr)
        sys.exit(1)
