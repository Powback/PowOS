#!/usr/bin/env python3
"""tools/lint/xml-wellformed.py FILE... - every XML file parses (stdlib expat). Run by tools/lint/changed-lints.sh on
changed *.xml files, so the scoped gate's first pass and the pre-push hook refuse a malformed one.

WHY (11-26): 17ec6592 landed an AndroidManifest.xml with `--` inside a comment (not well-formed XML) and main's tip no
longer built an APK until 47932a80. Generated output (build/, out/, intermediates/, node_modules/, .gradle/) and test
fixtures/ (raw tool dumps, some deliberately not XML) are skipped.
Exit 0 all parse, 1 a file doesn't (path:line:col: why).
"""
import re
import sys
import xml.parsers.expat

SKIP = re.compile(r"(^|/)(build|out|intermediates|node_modules|\.gradle|fixtures)/")


def main(argv):
    bad = 0
    for path in argv:
        if not path.endswith(".xml") or SKIP.search(path):
            continue
        p = xml.parsers.expat.ParserCreate()
        try:
            with open(path, "rb") as f:
                p.ParseFile(f)
        except xml.parsers.expat.ExpatError as e:
            print(f"FAIL xml: {path}:{e.lineno}:{e.offset}: {xml.parsers.expat.ErrorString(e.code)}")
            bad += 1
        except OSError:
            continue
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
