# MIT License
# 
# Copyright (c) 2026 Fray
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# Stiff experimental 0.2.0; requires Bend 2.0.20 (private native ABI).
# Native C effects and dependencies are trusted, not formally verified.
# Build with Stiff scripts/build-native.sh, not bare bend -o.
# Requires libcurl and json-c; storage adds SQLite; server adds the scoped,
# patched libevent 2.2.2-alpha build. Setup/build tooling is not in this package.
# Source, pinned setup and usage: https://github.com/fraylabs/stiff
# Package instructions: https://github.com/fraylabs/stiff/blob/main/docs/bendhub.md
# Package anchor. Import public modules directly from this package hash.
import Base
import ./src/http.bend as Http
import ./src/io.bend as Io
import ./src/json.bend as Json
import ./src/url.bend as Url
import ./src/server.bend as Server
import ./src/app.bend as App
import ./src/router.bend as Router
import ./src/schema.bend as Schema
import ./src/store.bend as Store
import ./src/PROOF.bend as Proof

def version() -> String:
  "0.2.0"
