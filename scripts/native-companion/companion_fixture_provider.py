#!/usr/bin/env python3
# ENSO ad-hoc local override: loopback-only synthetic provider for CompanionTest E2E.
# It assumes OpenAI-compatible transcription/chat response shapes and contains no user text.
# Revalidate request/response schemas and loopback binding if provider clients change upstream.

import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    server_version = "VoiceInkCompanionFixture/1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length > 8 * 1024 * 1024:
            self.send_error(413)
            return
        self.rfile.read(length)

        if self.path == "/v1/audio/transcriptions":
            time.sleep(self.server.transcription_delay)
            self.respond({"text": "CompanionSyntheticOriginal"})
            return

        if self.path == "/v1/chat/completions":
            suggestion = {
                "suggestions": [
                    {
                        "original": "CompanionSyntheticOriginal",
                        "corrected": "CompanionSyntheticReplacement",
                        "reason": "Deterministic fixture correction",
                    }
                ]
            }
            self.respond(
                {
                    "choices": [
                        {
                            "index": 0,
                            "message": {
                                "role": "assistant",
                                "content": json.dumps(suggestion, separators=(",", ":")),
                            },
                            "finish_reason": "stop",
                        }
                    ]
                }
            )
            return

        self.send_error(404)

    def respond(self, payload):
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--transcription-delay", type=float, default=2.5)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.transcription_delay = args.transcription_delay
    server.serve_forever()


if __name__ == "__main__":
    main()
