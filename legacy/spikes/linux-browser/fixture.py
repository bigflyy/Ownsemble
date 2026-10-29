"""Loopback-only generated browser fixtures; never use provider/session data."""
from http.server import BaseHTTPRequestHandler
import io
import math
import re
import struct
import wave

HTML = b'''<!doctype html><meta charset="utf-8"><title>Generated fixture</title>
<button style="position:absolute;left:20px;top:20px;width:160px;height:80px">Play fixture</button>
<audio src="/tone.wav" loop preload="auto"></audio><script>
window.fixture={start:window.injected===true,click:false,focus:false,playing:false,audioError:null,assets:0};
document.querySelector('button').onclick=e=>{
fixture.click=e.isTrusted;fixture.focus=document.hasFocus();
document.querySelector('audio').play().then(()=>fixture.playing=true).catch(e=>fixture.audioError=e.name);
};
fetch('/asset').then(r=>r.text()).then(()=>{fixture.assets++;
return fetch('/asset',{cache:'force-cache'});}).then(r=>r.text()).then(()=>fixture.assets++);
</script>'''

class Fixture(BaseHTTPRequestHandler):
    asset_requests = 0
    audio_requests = 0
    def log_message(self, *_):
        pass
    def do_GET(self):
        if self.path == '/asset':
            type(self).asset_requests += 1
            data, content = b'generated-cache-witness', 'text/plain'
        elif self.path == '/tone.wav':
            type(self).audio_requests += 1
            buffer = io.BytesIO()
            with wave.open(buffer, 'wb') as audio:
                audio.setparams((1, 2, 8000, 16000, 'NONE', 'not compressed'))
                audio.writeframes(b''.join(struct.pack('<h', int(500 * math.sin(i * math.tau * 440 / 8000))) for i in range(16000)))
            data, content = buffer.getvalue(), 'audio/wav'
        else:
            data, content = (HTML if self.path == '/page0' else b'<script>window.fixture={click:false,start:window.injected===true};</script>'), 'text/html'
        status, content_range = 200, None
        value = self.headers.get('Range')
        if value and self.path == '/tone.wav':
            match = re.fullmatch(r'bytes=(\d*)-(\d*)', value)
            length = len(data)
            start = end = None
            if match and any(match.groups()):
                first, last = match.groups()
                start = int(first) if first else max(0, length - int(last))
                end = min(int(last), length - 1) if first and last else length - 1
            if start is None or start >= length or end < start:
                self.send_response(416)
                self.send_header('Content-Range', f'bytes */{length}')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            content_range = f'bytes {start}-{end}/{length}'
            data, status = data[start:end + 1], 206
        self.send_response(status)
        self.send_header('Accept-Ranges', 'bytes')
        if content_range:
            self.send_header('Content-Range', content_range)
        self.send_header('Content-Type', content)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'public,max-age=3600' if self.path == '/asset' else 'no-store')
        self.end_headers()
        self.wfile.write(data)
