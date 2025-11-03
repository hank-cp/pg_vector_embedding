#!/usr/bin/env python3
import json
import random
from http.server import HTTPServer, BaseHTTPRequestHandler
import sys

class MockEmbeddingHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == '/v1/embeddings':
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            
            try:
                request_data = json.loads(post_data.decode('utf-8'))
                model = request_data.get('model', 'mock-model')
                input_text = request_data.get('input', '')
                
                embedding_dim = 1024
                embedding = [random.uniform(-0.1, 0.1) for _ in range(embedding_dim)]
                
                token_count = len(input_text.split())
                
                response = {
                    "object": "list",
                    "data": [{
                        "embedding": embedding,
                        "index": 0,
                        "object": "embedding"
                    }],
                    "model": model,
                    "usage": {
                        "prompt_tokens": token_count,
                        "completion_tokens": 0,
                        "total_tokens": token_count
                    }
                }
                
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(response).encode('utf-8'))
                
            except Exception as e:
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                error_response = {"error": str(e)}
                self.wfile.write(json.dumps(error_response).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, format, *args):
        sys.stderr.write("%s - - [%s] %s\n" %
                         (self.address_string(),
                          self.log_date_time_string(),
                          format % args))

def run_server(port=8080):
    server_address = ('', port)
    httpd = HTTPServer(server_address, MockEmbeddingHandler)
    print(f'Mock embedding server running on port {port}', file=sys.stderr)
    httpd.serve_forever()

if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    run_server(port)
