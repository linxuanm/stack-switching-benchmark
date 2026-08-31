#!/usr/bin/env python3
"""Wrap a .wasm module into a .wast script the reference interpreter will run.

`wasm foo.wasm` only *decodes and validates* a module -- it never instantiates
it, and each CLI argument is evaluated as an independent script, so
`wasm foo.wasm -e '(invoke "_start")'` fails with "no module instance defined".
Execution therefore requires a single .wast script holding both the module and
the commands that drive it.
"""
import argparse, sys

CHUNK = 2048


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("wasm", help="input .wasm module")
    ap.add_argument("-o", "--output", default="-", help="output .wast (default stdout)")
    ap.add_argument("--invoke", default="_start",
                    help="exported function to invoke (empty string for none)")
    a = ap.parse_args()

    data = open(a.wasm, "rb").read()
    out = ["(module binary"]
    for i in range(0, len(data), CHUNK):
        out.append('  "' + "".join("\\%02x" % c for c in data[i:i + CHUNK]) + '"')
    out.append(")")
    if a.invoke:
        out.append('(invoke "%s")' % a.invoke)
    text = "\n".join(out) + "\n"

    if a.output == "-":
        sys.stdout.write(text)
    else:
        open(a.output, "w").write(text)


if __name__ == "__main__":
    main()
