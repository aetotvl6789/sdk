// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../elements/entities.dart';
import '../elements/types.dart';
import 'member_usage.dart';
import 'use.dart';

abstract class ResolutionWorldBuilderForEnqueuer {
  Iterable<ClassEntity> get directlyInstantiatedClasses;

  Iterable<MemberEntity> get processedMembers;

  void registerTypeInstantiation(
      InterfaceType type, ClassUsedCallback classUsed,
      {ConstructorEntity? constructor});

  void processClassMembers(ClassEntity cls, MemberUsedCallback memberUsed,
      {bool checkEnqueuerConsistency = false});

  void registerDynamicUse(DynamicUse dynamicUse, MemberUsedCallback memberUsed);

  bool registerConstantUse(ConstantUse use);

  void registerStaticUse(StaticUse staticUse, MemberUsedCallback memberUsed);

  void registerTypeVariableTypeLiteral(TypeVariableType typeVariable);

  void registerIsCheck(covariant DartType type);

  void registerNamedTypeVariableNewRti(TypeVariableType type);

  void registerClosurizedMember(MemberEntity element);

  bool isMemberProcessed(MemberEntity member);

  void registerProcessedMember(MemberEntity member);

  void registerUsedElement(MemberEntity element);

  void registerClass(ClassEntity cls);
}
