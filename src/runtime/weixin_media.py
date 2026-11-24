"""The iLink CDN client. It only contacts HTTPS media hosts under weixin.qq.com."""

import base64
import hashlib
from pathlib import Path
import re
import secrets
import subprocess
from urllib.error import URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


CDN = 'https://novac2c.cdn.weixin.qq.com/c2c'
MAX_SIZE = 50 * 1024 * 1024
IMAGE_TYPES = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic'}
VIDEO_TYPES = {'.mp4', '.mov', '.m4v'}
ITEM_TYPES = {2: 'image', 3: 'voice', 4: 'file', 5: 'video'}


class MediaError(Exception):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def cdn_request(url, data=None):
    try:
        target = urlsplit(url)
    except ValueError:
        raise MediaError('微信附件地址格式无效') from None
    if (target.scheme != 'https' or not target.hostname or not target.hostname.endswith('.weixin.qq.com')
            or target.netloc != target.hostname or target.fragment):
        raise MediaError('微信附件地址不在支持的 CDN 范围内')
    headers = {'Content-Type': 'application/octet-stream'} if data is not None else {}
    try:
        with build_opener(NoRedirect).open(Request(url, data=data, headers=headers), timeout=22) as response:
            if data is not None:
                parameter = response.headers.get('x-encrypted-param')
                if response.status != 200 or not parameter:
                    raise MediaError('微信 CDN 没有返回上传凭证')
                return parameter
            content = response.read(MAX_SIZE + 17)
            if len(content) > MAX_SIZE + 16:
                raise MediaError('微信附件超过 50 MiB')
            return content
    except (URLError, OSError):
        raise MediaError('微信 CDN 请求失败') from None


def aes(root, mode, key, content):
    if len(key) != 16:
        raise MediaError('微信附件的加密密钥长度无效')
    try:
        result = subprocess.run([root / 'runtime' / 'node' / 'node.exe',
                                 root / 'src' / 'runtime' / 'weixin-media-crypto.mjs', mode],
                                input=key + content, capture_output=True, check=True, timeout=15,
                                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    except (OSError, subprocess.SubprocessError):
        raise MediaError('微信附件加密或解密失败') from None
    return result.stdout


def name_for(value, fallback):
    if not isinstance(value, str):
        return fallback
    name = re.sub(r'[\x00-\x1f<>:"/\\|?*]', '_', value).strip(' .')
    if not name:
        return fallback
    if re.fullmatch(r'CON|PRN|AUX|NUL|COM[0-9¹²³]|LPT[0-9¹²³]', name.split('.')[0], re.I):
        name = '_' + name
    if len(name) > 100:
        suffix = Path(name).suffix[:18]
        name = name[:100 - len(suffix)] + suffix
    return name


def decode_key(item, kind):
    media = item.get('media') or {}
    try:
        if kind == 'image' and item.get('aeskey'):
            return bytes.fromhex(item['aeskey'])
        if media.get('aes_key'):
            key = base64.b64decode(media['aes_key'], validate=True)
            return bytes.fromhex(key.decode('ascii')) if len(key) == 32 else key
    except (ValueError, TypeError):
        raise MediaError('微信附件的加密密钥格式无效') from None
    if kind != 'image':
        raise MediaError('微信附件缺少解密密钥')
    return None


def download(root, item, kind):
    media = item.get('media')
    if not isinstance(media, dict):
        raise MediaError('微信附件没有原文件下载引用')
    url = media.get('full_url')
    if not isinstance(url, str) or not url:
        parameter = media.get('encrypt_query_param')
        if not isinstance(parameter, str) or not parameter:
            raise MediaError('微信附件没有可用的下载地址')
        url = CDN + '/download?' + urlencode({'encrypted_query_param': parameter})
    key = decode_key(item, kind)
    content = cdn_request(url)
    if key is not None:
        content = aes(root, 'decrypt', key, content)
    if len(content) > MAX_SIZE:
        raise MediaError('微信附件超过 50 MiB')
    if kind == 'file' and item.get('len') not in (None, ''):
        if str(item['len']) != str(len(content)):
            raise MediaError('微信附件大小与消息记录不一致')
    return content


def received_name(kind, name, content):
    if kind == 'image':
        signatures = ((b'\xff\xd8\xff', 'jpg'), (b'\x89PNG\r\n\x1a\n', 'png'), (b'GIF8', 'gif'), (b'BM', 'bmp'))
        for signature, extension in signatures:
            if content.startswith(signature):
                return '图片.' + extension
        if content.startswith(b'RIFF') and content[8:12] == b'WEBP':
            return '图片.webp'
    return name


def upload(root, client, owner, path, kind, name):
    with path.open('rb') as source:
        content = source.read(MAX_SIZE + 1)
    if len(content) > MAX_SIZE:
        raise MediaError('微信附件超过 50 MiB')
    key = secrets.token_bytes(16)
    file_key = secrets.token_hex(16)
    ciphertext = aes(root, 'encrypt', key, content)
    uploaded = client('getuploadurl', {
        'filekey': file_key, 'media_type': {'image': 1, 'video': 2, 'file': 3}[kind],
        'to_user_id': owner, 'rawsize': len(content), 'rawfilemd5': hashlib.md5(content).hexdigest(),
        'filesize': len(ciphertext), 'aeskey': key.hex(), 'no_need_thumb': True,
    })
    url = uploaded.get('upload_full_url')
    if not isinstance(url, str) or not url:
        parameter = uploaded.get('upload_param')
        if not isinstance(parameter, str) or not parameter:
            raise MediaError('微信没提供附件上传地址')
        url = CDN + '/upload?' + urlencode({'encrypted_query_param': parameter, 'filekey': file_key})
    reference = {
        'encrypt_query_param': cdn_request(url, ciphertext),
        'aes_key': base64.b64encode(key.hex().encode()).decode(), 'encrypt_type': 1,
    }
    if kind == 'image':
        return {'type': 2, 'image_item': {'media': reference, 'mid_size': len(ciphertext)}}
    if kind == 'video':
        return {'type': 5, 'video_item': {'media': reference, 'video_size': len(ciphertext)}}
    return {'type': 4, 'file_item': {'media': reference, 'file_name': name, 'len': str(len(content))}}
