// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// part of "developer.dart";

@patch
bool _isDartStreamEnabled() => false;

@patch
int _getTraceClock() => _traceClock++;

int _traceClock = 0;

@patch
int _getNextAsyncId() => 0;

@patch
void _reportTaskEvent(int taskId, String phase, String category, String name,
    String argumentsAsJson) {}

@patch
void _reportFlowEvent(
    String category, String name, int type, int id, String argumentsAsJson) {}

@patch
void _reportInstantEvent(
    String category, String name, String argumentsAsJson) {}
