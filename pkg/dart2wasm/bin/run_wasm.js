// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// Runner V8 script for testing dart2wasm, takes ".wasm" file as argument.
// Run as follows:
//
// $> d8 --experimental-wasm-gc run_wasm.js -- <file_name>.wasm

// Load binary wasm file.
var bytes = readbuffer(arguments[0]);

// Create a Wasm module from the arraybuffer bytes.
var module = new WebAssembly.Module(bytes);

var writeFun = (typeof write !== 'undefined') ? write : process.stdout.write;
function printChar(char) {
    write(String.fromCharCode(char));
}

// Instantiate Wasm module, importing some functions.
var importObject = {
    console: {
        log: console.log
    },
    dart2wasm: {
        printChar: printChar
    },
    Date: {
        now: Date.now
    },
    math: {
        acos: Math.acos,
        asin: Math.asin,
        atan: Math.atan,
        atan2: Math.atan2,
        cos: Math.cos,
        exp: Math.exp,
        log: Math.log,
        pow: Math.pow,
        sin: Math.sin,
        sqrt: Math.sqrt,
        tan: Math.tan
    }
};
var inst = new WebAssembly.Instance(module, importObject);

var result = inst.exports.main();
if (result) console.log(result);
