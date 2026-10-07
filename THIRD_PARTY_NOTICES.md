# Third-party notices

Robo Tribute is licensed under the GNU General Public License v3 (see `LICENSE`). It is a re-implementation of
Robo 3T and contains or links the following third-party material.

## Robo 3T (formerly Robomongo)

- Source: https://github.com/Studio3T/robomongo
- License: GNU General Public License v3
- Copyright: 3T Software Labs Ltd. and the Robomongo / Robo 3T contributors
- Used: the icons in `Sources/RoboTribute/Resources/icons` (except the `qt_*` files); the user interface layout,
  texts, colors and keyboard shortcuts; the document formatting rules of `BsonUtils.cpp` and the relaxed JSON
  parsing rules of `json.cpp`, re-implemented in Swift.

"Robo 3T" and "Studio 3T" are trademarks of 3T Software Labs Ltd. This project is not affiliated with or endorsed by
3T Software Labs.

## Qt standard icons

- Files: `Sources/RoboTribute/Resources/icons/qt_open_32.png`, `qt_save_32.png`, `qt_info_32.png`
- Source: Qt 6 widget style images (the toolbar icons Robo 3T used on macOS)
- License: GNU LGPL v3 / GNU GPL v3; Copyright The Qt Company Ltd.

## Esprima 4.0.1

- File: `Sources/RoboTribute/Resources/esprima.js`
- License: BSD 2-Clause; Copyright JS Foundation and other contributors

```
Redistribution and use in source and binary forms, with or without modification, are permitted provided that the
following conditions are met:

  * Redistributions of source code must retain the above copyright notice, this list of conditions and the
    following disclaimer.
  * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the
    following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Statically linked libraries

Built by `scripts/build-deps.sh` and linked into the application binary. The app bundle ships their full license
texts in `Contents/Resources/Licenses`.

- MongoDB C Driver 2.5.5 (libmongoc, libbson): Apache License 2.0, Copyright MongoDB, Inc.
  https://github.com/mongodb/mongo-c-driver
- OpenSSL 4.0.3: Apache License 2.0, Copyright The OpenSSL Project Authors. https://www.openssl.org
