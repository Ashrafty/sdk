// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// Runner V8 script for testing dart2wasm, takes ".wasm" file as argument.
// Run as follows:
//
// $> d8 --experimental-wasm-gc run.js -- <file_name>.wasm

// Load binary wasm file.
var bytes = readbuffer(arguments[0]);

// Create a Wasm module from the arraybuffer bytes.
var module = new WebAssembly.Module(bytes);

// Instantiate Wasm module, importing some functions.
var importObject = {
    console: {
        log: console.log
    },
    Date: {
        now: Date.now
    }
};
var inst = new WebAssembly.Instance(module, importObject);

var result = inst.exports.main();
if (result) console.log(result);
