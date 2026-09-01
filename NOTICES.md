# Jarvis Topic Manager — Third-Party Notices

Copyright (c) 2025-2026 James Rodman. All Rights Reserved.

This product includes software developed by third parties under the following licenses.

The versions below are the ones in `requirements.txt` (the single source of truth for every
Python pin) and the Vue pin in `install/upgrade-full.sh`. `SBOM.md` lists the same set with
sources and vulnerability status; if these two files ever disagree, one of them is wrong.

> A host installed by `install.sh` and never upgraded serves Vue **3.5.35**, which that
> script fetches without an integrity check. Upgraded hosts serve the hash-verified 3.5.42
> recorded below. See SBOM.md → *Known divergence*.

---

## Vue.js
Version: 3.5.42
License: MIT
Copyright (c) 2013-present, Yuxi (Evan) You

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.

---

## Flask
Version: 3.1.3
License: BSD-3-Clause
Copyright 2010 Pallets

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
1. Redistributions of source code must retain the above copyright notice.
2. Redistributions in binary form must reproduce the above copyright notice.
3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

---

## gunicorn
Version: 26.2.0
License: MIT
Copyright 2009-2015 (c) Benoît Chesneau; 2009-2015 (c) Paul J. Davis

---

## ldap3
Version: 2.9.1
License: LGPL-3.0
Copyright 2013-2022 Giovanni Cannata

---

## confluent-kafka-python
Version: 2.15.0
License: Apache-2.0
Copyright 2016-2024 Confluent Inc.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License.
You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

---

## PyYAML
Version: 6.0.3
License: MIT
Copyright (c) 2017-2021 Ingy döt Net; Copyright (c) 2006-2016 Kirill Simonov

---

## cryptography
Version: 50.0.1
License: Apache-2.0 OR BSD-3-Clause
Copyright (c) Individual contributors.

---

## Werkzeug
Version: 3.1.8
License: BSD-3-Clause
Copyright 2007 Pallets

---

## SQLite
Version: 3.x
License: Public Domain
Source: sqlite.org

SQLite is in the public domain. No attribution is required, but the authors
request that credit be given where possible. The SQLite source code is
available at https://www.sqlite.org/download.html.

---

## Transitive dependencies

These are not named in `requirements.txt` but are installed into the runtime
virtual environment as dependencies of the packages above, so they ship with the
product and their licences apply. Versions and licence expressions were read
from each package's own `dist-info/METADATA` on the deployed host (2026-09-01).

| Component | Version | License | Required by |
|-----------|---------|---------|-------------|
| Jinja2 | 3.1.6 | BSD-3-Clause | Flask |
| MarkupSafe | 3.0.3 | BSD-3-Clause | Jinja2, Werkzeug |
| itsdangerous | 2.2.0 | BSD-3-Clause | Flask |
| click | 8.5.0 | BSD-3-Clause | Flask |
| blinker | 1.9.0 | MIT | Flask |
| cffi | 2.1.1 | MIT-0 | cryptography |
| pycparser | 3.0 | BSD-3-Clause | cffi |
| pyasn1 | 0.6.4 | BSD-2-Clause | ldap3 |

Full licence texts ship inside each package's `dist-info` directory in the
virtual environment at `/opt/topic-manager/venv`.

---

## nginx
License: BSD-2-Clause
Copyright (c) 2002-2021 Igor Sysoev; Copyright (c) 2011-2021 Nginx, Inc.

---

## Apache Kafka
License: Apache-2.0
Copyright (c) Apache Software Foundation

Licensed under the Apache License, Version 2.0.
