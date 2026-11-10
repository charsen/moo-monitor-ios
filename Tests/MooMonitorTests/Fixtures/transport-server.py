import http.server
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
mode = sys.argv[2]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        with (root/'requests.jsonl').open('a') as log:
            log.write(json.dumps({'path':self.path,'cookie':self.headers.get('Cookie'),'token':self.headers.get('X-Project-Token')})+'\n')
        if self.path == '/sink':
            self.send_response(200); self.end_headers(); self.wfile.write(b'{}')
        elif mode == 'redirect':
            self.send_response(302); self.send_header('Location',f'http://127.0.0.1:{self.server.server_port}/sink'); self.end_headers()
        else:
            self.send_response(401); self.send_header('WWW-Authenticate','Basic realm="isolated fixture"'); self.end_headers()
    def log_message(self,*args): pass
server = http.server.HTTPServer(('127.0.0.1',0),Handler)
(root/'port').write_text(str(server.server_port))
server.serve_forever()
