// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart';

Expando<Reference> _tearOffReference = Expando();

extension TearOffReference on Procedure {
  Reference get tearOffReference =>
      _tearOffReference[this] ??= Reference()..node = this;
}

extension IsTearOffReference on Reference {
  bool get isTearOffReference {
    Member member = asMember;
    return member is Procedure && member.tearOffReference == this;
  }
}
