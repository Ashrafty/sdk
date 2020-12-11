// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// Runner V8 script for testing dart2wasm, takes ".wasm" file as argument.
// Run as follows:
//
// $> d8 --experimental-wasm-gc run.js -- <file_name>.wasm
//
// For debugging, you'll need a debug build of V8 and adding the additional flag
// --trace-wasm-decoder.

// Load binary wasm file (e.g. created by running wat2wasm on a ".wat" file).
var bytes = readbuffer(arguments[0]);
console.log("Read binary file!");

// Create a Wasm module from the arraybuffer bytes.
var module = new WebAssembly.Module(bytes);
console.log("Created module!");

// Instantiate Wasm module, importing console.log as the Dart print function.
var importObject = {
    console: {
        log: arg => console.log(arg)
    }
};
var inst = new WebAssembly.Instance(module, importObject);

console.log("Instantiated module!");

console.log(inst.exports.sequence(12, 34));
