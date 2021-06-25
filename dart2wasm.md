## Running the dart2wasm prototype

If you already have a Dart SDK checkout, you can check out the prototype as a branch:
```
git fetch git@github.com:askeksa-google/sdk.git wasm_prototype && git checkout FETCH_HEAD -b wasm_prototype
```
Otherwise, do (assuming you have [depot_tools](https://commondatastorage.googleapis.com/chrome-infra-docs/flat/depot_tools/docs/html/depot_tools_tutorial.html) installed):
```
mkdir dart-sdk
cd dart-sdk
gclient config git@github.com:askeksa-google/sdk.git
git clone git@github.com:askeksa-google/sdk.git
cd sdk
gclient sync
git checkout wasm_prototype
```
You don't need to build the Dart SDK to run the prototype, as long as you have a Dart SDK installed.

To compile a Dart file to Wasm, run:

`dart --no-sound-null-safety --enable-asserts pkg/dart2wasm/bin/dart2wasm.dart` *options* *infile*`.dart` *outfile*`.wasm`

where *options* include:

| Option                                  | Default | Description |
| --------------------------------------- | ------- | ----------- |
| `--`[`no-`]`export-all`                 | no      | Export all functions; otherwise, just export `main`.
| `--`[`no-`]`inlining`                   | no      | Inline small functions.
| `--`[`no-`]`local-nullability`          | no      | Use non-nullable types for non-nullable locals and temporaries.
| `--`[`no-`]`nominal-types`              | no      | Emit experimental nominal types.
| `--`[`no-`]`parameter-nullability`      | yes     | Use non-nullable types for non-nullable parameters and return values.
| `--`[`no-`]`polymorphic-specialization` | no      | Do virtual calls by switching on the class ID instead of using `call_indirect`.
| `--`[`no-`]`print-kernel`               | no      | Print IR for each function before compiling it.
| `--`[`no-`]`print-wasm`                 | no      | Print Wasm instructions of each compiled function.
| `--`[`no-`]`stub-bodies`                | no      | Skip translation of function bodies and just put `unreachable`.
| `--watch` *offset*                      |         | Print stack trace leading to the byte at offset *offset* in the `.wasm` output file. Can be specified multiple times.

The resulting `.wasm` file can be run with:

`d8 --experimental-wasm-gc pkg/dart2wasm/bin/run_wasm.js -- `*outfile*`.wasm`
