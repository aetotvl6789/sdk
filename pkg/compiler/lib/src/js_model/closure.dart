// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart = 2.10

import 'package:kernel/ast.dart' as ir;

import '../closure.dart';
import '../common.dart';
import '../elements/entities.dart';
import '../elements/types.dart';
import '../ir/closure.dart';
import '../ir/element_map.dart';
import '../ir/static_type_cache.dart';
import '../js_backend/annotations.dart';
import '../js_model/class_type_variable_access.dart';
import '../js_model/element_map.dart';
import '../js_model/env.dart';
import '../ordered_typeset.dart';
import '../serialization/deferrable.dart';
import '../serialization/serialization.dart';
import '../universe/selector.dart';
import 'elements.dart';
import 'closure_migrated.dart' as migrated;
import 'js_world_builder.dart' show JsClosedWorldBuilder;

export 'closure_migrated.dart'
    show AnonymousClosureLocal, JClosureField, JRecordField;

class ClosureDataImpl implements ClosureData {
  /// Tag used for identifying serialized [ClosureData] objects in a
  /// debugging data stream.
  static const String tag = 'closure-data';

  final JsToElementMap _elementMap;

  /// Map of the scoping information that corresponds to a particular entity.
  final Deferrable<Map<MemberEntity, ScopeInfo>> _scopeMap;
  final Deferrable<Map<ir.TreeNode, CapturedScope>> _capturedScopesMap;
  // Indicates the type variables (if any) that are captured in a given
  // Signature function.
  final Deferrable<Map<MemberEntity, CapturedScope>>
      _capturedScopeForSignatureMap;

  final Deferrable<Map<ir.LocalFunction, ClosureRepresentationInfo>>
      _localClosureRepresentationMap;

  final Map<MemberEntity, MemberEntity> _enclosingMembers;

  ClosureDataImpl(
      this._elementMap,
      Map<MemberEntity, ScopeInfo> scopeMap,
      Map<ir.TreeNode, CapturedScope> capturedScopesMap,
      Map<MemberEntity, CapturedScope> capturedScopeForSignatureMap,
      Map<ir.LocalFunction, ClosureRepresentationInfo>
          localClosureRepresentationMap,
      this._enclosingMembers)
      : _scopeMap = Deferrable.eager(scopeMap),
        _capturedScopesMap = Deferrable.eager(capturedScopesMap),
        _capturedScopeForSignatureMap =
            Deferrable.eager(capturedScopeForSignatureMap),
        _localClosureRepresentationMap =
            Deferrable.eager(localClosureRepresentationMap);

  ClosureDataImpl._deserialized(
      this._elementMap,
      this._scopeMap,
      this._capturedScopesMap,
      this._capturedScopeForSignatureMap,
      this._localClosureRepresentationMap,
      this._enclosingMembers);

  /// Deserializes a [ClosureData] object from [source].
  factory ClosureDataImpl.readFromDataSource(
      JsToElementMap elementMap, DataSourceReader source) {
    source.begin(tag);
    // TODO(johnniwinther): Support shared [ScopeInfo].
    final scopeMap = source.readDeferrable(() => source.readMemberMap(
        (MemberEntity member) => ScopeInfo.readFromDataSource(source)));
    final capturedScopesMap = source.readDeferrable(() =>
        source.readTreeNodeMap(() => CapturedScope.readFromDataSource(source)));
    final capturedScopeForSignatureMap = source.readDeferrable(() =>
        source.readMemberMap(
            (MemberEntity member) => CapturedScope.readFromDataSource(source)));
    final localClosureRepresentationMap = source.readDeferrable(() =>
        source.readTreeNodeMap<ir.LocalFunction, ClosureRepresentationInfo>(
            () => ClosureRepresentationInfo.readFromDataSource(source)));
    Map<MemberEntity, MemberEntity> enclosingMembers =
        source.readMemberMap((member) => source.readMember());
    source.end(tag);
    return ClosureDataImpl._deserialized(
        elementMap,
        scopeMap,
        capturedScopesMap,
        capturedScopeForSignatureMap,
        localClosureRepresentationMap,
        enclosingMembers);
  }

  /// Serializes this [ClosureData] to [sink].
  @override
  void writeToDataSink(DataSinkWriter sink) {
    sink.begin(tag);
    sink.writeDeferrable(() => sink.writeMemberMap(_scopeMap.loaded(),
        (MemberEntity member, ScopeInfo info) => info.writeToDataSink(sink)));
    sink.writeDeferrable(() => sink.writeTreeNodeMap(
            _capturedScopesMap.loaded(), (CapturedScope scope) {
          scope.writeToDataSink(sink);
        }));
    sink.writeDeferrable(() => sink.writeMemberMap(
        _capturedScopeForSignatureMap.loaded(),
        (MemberEntity member, CapturedScope scope) =>
            scope.writeToDataSink(sink)));
    sink.writeDeferrable(() => sink
            .writeTreeNodeMap(_localClosureRepresentationMap.loaded(),
                (ClosureRepresentationInfo info) {
          info.writeToDataSink(sink);
        }));
    sink.writeMemberMap(_enclosingMembers,
        (MemberEntity member, MemberEntity value) {
      sink.writeMember(value);
    });
    sink.end(tag);
  }

  @override
  ScopeInfo getScopeInfo(MemberEntity entity) {
    // TODO(johnniwinther): Remove this check when constructor bodies a created
    // eagerly with the J-model; a constructor body should have it's own
    // [ClosureRepresentationInfo].
    if (entity is ConstructorBodyEntity) {
      ConstructorBodyEntity constructorBody = entity;
      entity = constructorBody.constructor;
    }

    ScopeInfo scopeInfo = _scopeMap.loaded()[entity];
    assert(
        scopeInfo != null, failedAt(entity, "Missing scope info for $entity."));
    return scopeInfo;
  }

  // TODO(efortuna): Eventually capturedScopesMap[node] should always
  // be non-null, and we should just test that with an assert.
  @override
  CapturedScope getCapturedScope(MemberEntity entity) {
    MemberDefinition definition = _elementMap.getMemberDefinition(entity);
    switch (definition.kind) {
      case MemberKind.regular:
      case MemberKind.constructor:
      case MemberKind.constructorBody:
      case MemberKind.closureCall:
        return _capturedScopesMap.loaded()[definition.node] ??
            const CapturedScope();
      case MemberKind.signature:
        return _capturedScopeForSignatureMap.loaded()[entity] ??
            const CapturedScope();
      default:
        throw failedAt(entity, "Unexpected member definition $definition");
    }
  }

  @override
  // TODO(efortuna): Eventually capturedScopesMap[node] should always
  // be non-null, and we should just test that with an assert.
  CapturedLoopScope getCapturedLoopScope(ir.Node loopNode) =>
      _capturedScopesMap.loaded()[loopNode] ?? const CapturedLoopScope();

  @override
  ClosureRepresentationInfo getClosureInfo(ir.LocalFunction node) {
    var closure = _localClosureRepresentationMap.loaded()[node];
    assert(
        closure != null,
        "Corresponding closure class not found for $node. "
        "Closures found for ${_localClosureRepresentationMap.loaded().keys}");
    return closure;
  }

  @override
  MemberEntity getEnclosingMember(MemberEntity member) {
    return _enclosingMembers[member] ?? member;
  }
}

/// Closure conversion code using our new Entity model. Closure conversion is
/// necessary because the semantics of closures are slightly different in Dart
/// than JavaScript. Closure conversion is separated out into two phases:
/// generation of a new (temporary) representation to store where variables need
/// to be hoisted/captured up at another level to re-write the closure, and then
/// the code generation phase where we generate elements and/or instructions to
/// represent this new code path.
///
/// For a general explanation of how closure conversion works at a high level,
/// check out:
/// http://siek.blogspot.com/2012/07/essence-of-closure-conversion.html or
/// http://matt.might.net/articles/closure-conversion/.

class ClosureDataBuilder {
  final DiagnosticReporter _reporter;
  final JsToElementMap _elementMap;
  final AnnotationsData _annotationsData;

  /// Map of the scoping information that corresponds to a particular entity.
  final Map<MemberEntity, ScopeInfo> _scopeMap = {};
  final Map<ir.TreeNode, CapturedScope> _capturedScopesMap = {};
  // Indicates the type variables (if any) that are captured in a given
  // Signature function.
  final Map<MemberEntity, CapturedScope> _capturedScopeForSignatureMap = {};

  final Map<ir.LocalFunction, ClosureRepresentationInfo>
      _localClosureRepresentationMap = {};

  final Map<MemberEntity, MemberEntity> _enclosingMembers = {};

  ClosureDataBuilder(this._reporter, this._elementMap, this._annotationsData);

  void _updateScopeBasedOnRtiNeed(KernelScopeInfo scope, ClosureRtiNeed rtiNeed,
      MemberEntity outermostEntity) {
    bool includeForRti(Set<VariableUse> useSet) {
      for (VariableUse usage in useSet) {
        switch (usage.kind) {
          case VariableUseKind.explicit:
            return true;
            break;
          case VariableUseKind.implicitCast:
            if (_annotationsData
                .getImplicitDowncastCheckPolicy(outermostEntity)
                .isEmitted) {
              return true;
            }
            break;
          case VariableUseKind.localType:
            break;
          case VariableUseKind.constructorTypeArgument:
            ConstructorEntity constructor =
                _elementMap.getConstructor(usage.member);
            if (rtiNeed.classNeedsTypeArguments(constructor.enclosingClass)) {
              return true;
            }
            break;
          case VariableUseKind.staticTypeArgument:
            FunctionEntity method = _elementMap.getMethod(usage.member);
            if (rtiNeed.methodNeedsTypeArguments(method)) {
              return true;
            }
            break;
          case VariableUseKind.instanceTypeArgument:
            Selector selector = _elementMap.getSelector(usage.invocation);
            if (rtiNeed.selectorNeedsTypeArguments(selector)) {
              return true;
            }
            break;
          case VariableUseKind.localTypeArgument:
            // TODO(johnniwinther): We should be able to track direct local
            // function invocations and not have to use the selector here.
            Selector selector = _elementMap.getSelector(usage.invocation);
            if (rtiNeed.localFunctionNeedsTypeArguments(usage.localFunction) ||
                rtiNeed.selectorNeedsTypeArguments(selector)) {
              return true;
            }
            break;
          case VariableUseKind.memberParameter:
            if (_annotationsData
                .getParameterCheckPolicy(outermostEntity)
                .isEmitted) {
              return true;
            } else {
              FunctionEntity method = _elementMap.getMethod(usage.member);
              if (rtiNeed.methodNeedsSignature(method)) {
                return true;
              }
            }
            break;
          case VariableUseKind.localParameter:
            if (_annotationsData
                .getParameterCheckPolicy(outermostEntity)
                .isEmitted) {
              return true;
            } else if (rtiNeed
                .localFunctionNeedsSignature(usage.localFunction)) {
              return true;
            }
            break;
          case VariableUseKind.memberReturnType:
            FunctionEntity method = _elementMap.getMethod(usage.member);
            if (rtiNeed.methodNeedsSignature(method)) {
              return true;
            }
            break;
          case VariableUseKind.localReturnType:
            if (usage.localFunction.function.asyncMarker !=
                ir.AsyncMarker.Sync) {
              // The Future/Iterator/Stream implementation requires the type.
              return true;
            }
            if (rtiNeed.localFunctionNeedsSignature(usage.localFunction)) {
              return true;
            }
            break;
          case VariableUseKind.fieldType:
            if (_annotationsData
                .getParameterCheckPolicy(outermostEntity)
                .isEmitted) {
              return true;
            }
            break;
          case VariableUseKind.listLiteral:
            if (rtiNeed.classNeedsTypeArguments(
                _elementMap.commonElements.jsArrayClass)) {
              return true;
            }
            break;
          case VariableUseKind.setLiteral:
            if (rtiNeed.classNeedsTypeArguments(
                _elementMap.commonElements.setLiteralClass)) {
              return true;
            }
            break;
          case VariableUseKind.mapLiteral:
            if (rtiNeed.classNeedsTypeArguments(
                _elementMap.commonElements.mapLiteralClass)) {
              return true;
            }
            break;
          case VariableUseKind.instantiationTypeArgument:
            // TODO(johnniwinther): Use the static type of the expression.
            if (rtiNeed.instantiationNeedsTypeArguments(
                null, usage.instantiation.typeArguments.length)) {
              return true;
            }
            break;
        }
      }
      return false;
    }

    if (includeForRti(scope.thisUsedAsFreeVariableIfNeedsRti)) {
      scope.thisUsedAsFreeVariable = true;
    }
    scope.freeVariablesForRti.forEach(
        (TypeVariableTypeWithContext typeVariable, Set<VariableUse> useSet) {
      if (includeForRti(useSet)) {
        scope.freeVariables.add(typeVariable);
      }
    });
  }

  ClosureData createClosureEntities(
      JsClosedWorldBuilder closedWorldBuilder,
      Map<MemberEntity, ClosureScopeModel> closureModels,
      ClosureRtiNeed rtiNeed,
      List<FunctionEntity> callMethods) {
    void processModel(MemberEntity member, ClosureScopeModel model) {
      Map<ir.VariableDeclaration, migrated.JRecordField> allBoxedVariables =
          _elementMap.makeRecordContainer(model.scopeInfo, member);
      _scopeMap[member] = JsScopeInfo.from(
          allBoxedVariables, model.scopeInfo, member.enclosingClass);

      model.capturedScopesMap
          .forEach((ir.Node node, KernelCapturedScope scope) {
        Map<ir.VariableDeclaration, migrated.JRecordField> boxedVariables =
            _elementMap.makeRecordContainer(scope, member);
        _updateScopeBasedOnRtiNeed(scope, rtiNeed, member);

        if (scope is KernelCapturedLoopScope) {
          _capturedScopesMap[node] = JsCapturedLoopScope.from(
              boxedVariables, scope, member.enclosingClass);
        } else {
          _capturedScopesMap[node] = JsCapturedScope.from(
              boxedVariables, scope, member.enclosingClass);
        }
        allBoxedVariables.addAll(boxedVariables);
      });

      Map<ir.LocalFunction, KernelScopeInfo> closuresToGenerate =
          model.closuresToGenerate;
      for (ir.LocalFunction node in closuresToGenerate.keys) {
        ir.FunctionNode functionNode = node.function;
        JsClosureClassInfo closureClassInfo = _produceSyntheticElements(
            closedWorldBuilder,
            member,
            functionNode,
            closuresToGenerate[node],
            allBoxedVariables,
            rtiNeed,
            createSignatureMethod:
                rtiNeed.localFunctionNeedsSignature(functionNode.parent));
        // Add also for the call method.
        _scopeMap[closureClassInfo.callMethod] = closureClassInfo;
        if (closureClassInfo.signatureMethod != null) {
          _scopeMap[closureClassInfo.signatureMethod] = closureClassInfo;

          // Set up capturedScope for signature method. This is distinct from
          // _capturedScopesMap because there is no corresponding ir.Node for
          // the signature.
          if (rtiNeed.localFunctionNeedsSignature(functionNode.parent) &&
              model.capturedScopesMap[functionNode] != null) {
            KernelCapturedScope capturedScope =
                model.capturedScopesMap[functionNode];
            assert(capturedScope is! KernelCapturedLoopScope);
            KernelCapturedScope signatureCapturedScope =
                KernelCapturedScope.forSignature(capturedScope);
            _updateScopeBasedOnRtiNeed(signatureCapturedScope, rtiNeed, member);
            _capturedScopeForSignatureMap[closureClassInfo.signatureMethod] =
                JsCapturedScope.from(
                    {}, signatureCapturedScope, member.enclosingClass);
          }
        }
        callMethods.add(closureClassInfo.callMethod);
      }
    }

    closureModels.forEach((MemberEntity member, ClosureScopeModel model) {
      _reporter.withCurrentElement(member, () {
        processModel(member, model);
      });
    });
    return ClosureDataImpl(
        _elementMap,
        _scopeMap,
        _capturedScopesMap,
        _capturedScopeForSignatureMap,
        _localClosureRepresentationMap,
        _enclosingMembers);
  }

  /// Given what variables are captured at each point, construct closure classes
  /// with fields containing the captured variables to replicate the Dart
  /// closure semantics in JS. If this closure captures any variables (meaning
  /// the closure accesses a variable that gets accessed at some point), then
  /// boxForCapturedVariables stores the local context for those variables.
  /// If no variables are captured, this parameter is null.
  JsClosureClassInfo _produceSyntheticElements(
      JsClosedWorldBuilder closedWorldBuilder,
      MemberEntity member,
      ir.FunctionNode node,
      KernelScopeInfo info,
      Map<ir.VariableDeclaration, migrated.JRecordField> boxedVariables,
      ClosureRtiNeed rtiNeed,
      {bool createSignatureMethod}) {
    _updateScopeBasedOnRtiNeed(info, rtiNeed, member);
    JsClosureClassInfo closureClassInfo = closedWorldBuilder.buildClosureClass(
        member, node, member.library, boxedVariables, info,
        createSignatureMethod: createSignatureMethod);

    // We want the original declaration where that function is used to point
    // to the correct closure class.
    _enclosingMembers[closureClassInfo.callMethod] = member;
    if (closureClassInfo.signatureMethod != null) {
      _enclosingMembers[closureClassInfo.signatureMethod] = member;
    }
    if (node.parent is ir.Member) {
      assert(_elementMap.getMember(node.parent) == member);
    } else {
      assert(node.parent is ir.LocalFunction);
      _localClosureRepresentationMap[node.parent] = closureClassInfo;
    }
    return closureClassInfo;
  }
}

class JsScopeInfo extends ScopeInfo {
  /// Tag used for identifying serialized [JsScopeInfo] objects in a
  /// debugging data stream.
  static const String tag = 'scope-info';

  final Iterable<ir.VariableDeclaration> _localsUsedInTryOrSync;

  Set<Local> _localsUsedInTryOrSyncCache;

  @override
  final Local thisLocal;

  final Map<ir.VariableDeclaration, migrated.JRecordField> _boxedVariables;

  Map<Local, migrated.JRecordField> _boxedVariablesCache;

  JsScopeInfo.internal(
      this._localsUsedInTryOrSync, this.thisLocal, this._boxedVariables);

  JsScopeInfo.from(
      this._boxedVariables, KernelScopeInfo info, ClassEntity enclosingClass)
      : this.thisLocal = info.hasThisLocal ? ThisLocal(enclosingClass) : null,
        this._localsUsedInTryOrSync = info.localsUsedInTryOrSync;

  void _ensureBoxedVariableCache(KernelToLocalsMap localsMap) {
    if (_boxedVariablesCache == null) {
      if (_boxedVariables.isEmpty) {
        _boxedVariablesCache = const {};
      } else {
        _boxedVariablesCache = {};
        _boxedVariables.forEach(
            (ir.VariableDeclaration node, migrated.JRecordField field) {
          _boxedVariablesCache[localsMap.getLocalVariable(node)] = field;
        });
      }
    }
  }

  @override
  void forEachBoxedVariable(
      KernelToLocalsMap localsMap, f(Local local, FieldEntity field)) {
    _ensureBoxedVariableCache(localsMap);
    _boxedVariablesCache.forEach(f);
  }

  @override
  bool localIsUsedInTryOrSync(KernelToLocalsMap localsMap, Local variable) {
    if (_localsUsedInTryOrSyncCache == null) {
      if (_localsUsedInTryOrSync.isEmpty) {
        _localsUsedInTryOrSyncCache = const {};
      } else {
        _localsUsedInTryOrSyncCache = {};
        for (ir.VariableDeclaration node in _localsUsedInTryOrSync) {
          _localsUsedInTryOrSyncCache.add(localsMap.getLocalVariable(node));
        }
      }
    }
    return _localsUsedInTryOrSyncCache.contains(variable);
  }

  @override
  String toString() {
    StringBuffer sb = StringBuffer();
    sb.write('this=$thisLocal,');
    sb.write('localsUsedInTryOrSync={${_localsUsedInTryOrSync.join(', ')}}');
    return sb.toString();
  }

  @override
  bool isBoxedVariable(KernelToLocalsMap localsMap, Local variable) {
    _ensureBoxedVariableCache(localsMap);
    return _boxedVariablesCache.containsKey(variable);
  }

  factory JsScopeInfo.readFromDataSource(DataSourceReader source) {
    source.begin(tag);
    Iterable<ir.VariableDeclaration> localsUsedInTryOrSync =
        source.readTreeNodes<ir.VariableDeclaration>();
    Local thisLocal = source.readLocalOrNull();
    Map<ir.VariableDeclaration, migrated.JRecordField> boxedVariables =
        source.readTreeNodeMap<ir.VariableDeclaration, migrated.JRecordField>(
            () => source.readMember());
    source.end(tag);
    if (boxedVariables.isEmpty) boxedVariables = const {};
    return JsScopeInfo.internal(
        localsUsedInTryOrSync, thisLocal, boxedVariables);
  }

  @override
  void writeToDataSink(DataSinkWriter sink) {
    sink.writeEnum(ScopeInfoKind.scopeInfo);
    sink.begin(tag);
    sink.writeTreeNodes(_localsUsedInTryOrSync);
    sink.writeLocalOrNull(thisLocal);
    sink.writeTreeNodeMap(_boxedVariables, sink.writeMember);
    sink.end(tag);
  }
}

class JsCapturedScope extends JsScopeInfo implements CapturedScope {
  /// Tag used for identifying serialized [JsCapturedScope] objects in a
  /// debugging data stream.
  static const String tag = 'captured-scope';

  @override
  final Local contextBox;

  JsCapturedScope.internal(
      Iterable<ir.VariableDeclaration> localsUsedInTryOrSync,
      Local thisLocal,
      Map<ir.VariableDeclaration, migrated.JRecordField> boxedVariables,
      this.contextBox)
      : super.internal(localsUsedInTryOrSync, thisLocal, boxedVariables);

  JsCapturedScope.from(
      Map<ir.VariableDeclaration, migrated.JRecordField> boxedVariables,
      KernelCapturedScope capturedScope,
      ClassEntity enclosingClass)
      : this.contextBox =
            boxedVariables.isNotEmpty ? boxedVariables.values.first.box : null,
        super.from(boxedVariables, capturedScope, enclosingClass);

  @override
  bool get requiresContextBox => _boxedVariables.isNotEmpty;

  factory JsCapturedScope.readFromDataSource(DataSourceReader source) {
    source.begin(tag);
    Iterable<ir.VariableDeclaration> localsUsedInTryOrSync =
        source.readTreeNodes<ir.VariableDeclaration>();
    Local thisLocal = source.readLocalOrNull();
    Map<ir.VariableDeclaration, migrated.JRecordField> boxedVariables =
        source.readTreeNodeMap<ir.VariableDeclaration, migrated.JRecordField>(
            () => source.readMember());
    Local context = source.readLocalOrNull();
    source.end(tag);
    return JsCapturedScope.internal(
        localsUsedInTryOrSync, thisLocal, boxedVariables, context);
  }

  @override
  void writeToDataSink(DataSinkWriter sink) {
    sink.writeEnum(ScopeInfoKind.capturedScope);
    sink.begin(tag);
    sink.writeTreeNodes(_localsUsedInTryOrSync);
    sink.writeLocalOrNull(thisLocal);
    sink.writeTreeNodeMap(_boxedVariables, sink.writeMember);
    sink.writeLocalOrNull(contextBox);
    sink.end(tag);
  }
}

class JsCapturedLoopScope extends JsCapturedScope implements CapturedLoopScope {
  /// Tag used for identifying serialized [JsCapturedLoopScope] objects in a
  /// debugging data stream.
  static const String tag = 'captured-loop-scope';

  final List<ir.VariableDeclaration> _boxedLoopVariables;

  JsCapturedLoopScope.internal(
      Iterable<ir.VariableDeclaration> localsUsedInTryOrSync,
      Local thisLocal,
      Map<ir.VariableDeclaration, migrated.JRecordField> boxedVariables,
      Local context,
      this._boxedLoopVariables)
      : super.internal(
            localsUsedInTryOrSync, thisLocal, boxedVariables, context);

  JsCapturedLoopScope.from(
      Map<ir.VariableDeclaration, migrated.JRecordField> boxedVariables,
      KernelCapturedLoopScope capturedScope,
      ClassEntity enclosingClass)
      : this._boxedLoopVariables = capturedScope.boxedLoopVariables,
        super.from(boxedVariables, capturedScope, enclosingClass);

  @override
  bool get hasBoxedLoopVariables => _boxedLoopVariables.isNotEmpty;

  factory JsCapturedLoopScope.readFromDataSource(DataSourceReader source) {
    source.begin(tag);
    Iterable<ir.VariableDeclaration> localsUsedInTryOrSync =
        source.readTreeNodes<ir.VariableDeclaration>();
    Local thisLocal = source.readLocalOrNull();
    Map<ir.VariableDeclaration, migrated.JRecordField> boxedVariables =
        source.readTreeNodeMap<ir.VariableDeclaration, migrated.JRecordField>(
            () => source.readMember());
    Local context = source.readLocalOrNull();
    List<ir.VariableDeclaration> boxedLoopVariables =
        source.readTreeNodes<ir.VariableDeclaration>();
    source.end(tag);
    return JsCapturedLoopScope.internal(localsUsedInTryOrSync, thisLocal,
        boxedVariables, context, boxedLoopVariables);
  }

  @override
  void writeToDataSink(DataSinkWriter sink) {
    sink.writeEnum(ScopeInfoKind.capturedLoopScope);
    sink.begin(tag);
    sink.writeTreeNodes(_localsUsedInTryOrSync);
    sink.writeLocalOrNull(thisLocal);
    sink.writeTreeNodeMap(_boxedVariables, sink.writeMember);
    sink.writeLocalOrNull(contextBox);
    sink.writeTreeNodes(_boxedLoopVariables);
    sink.end(tag);
  }

  @override
  List<Local> getBoxedLoopVariables(KernelToLocalsMap localsMap) {
    List<Local> locals = [];
    for (ir.VariableDeclaration boxedLoopVariable in _boxedLoopVariables) {
      locals.add(localsMap.getLocalVariable(boxedLoopVariable));
    }
    return locals;
  }
}

// TODO(johnniwinther): Add unittest for the computed [ClosureClass].
class JsClosureClassInfo extends JsScopeInfo
    implements ClosureRepresentationInfo, migrated.JsClosureClassInfo {
  /// Tag used for identifying serialized [JsClosureClassInfo] objects in a
  /// debugging data stream.
  static const String tag = 'closure-representation-info';

  @override
  JFunction callMethod;
  @override
  JSignatureMethod signatureMethod;

  /// The local used for this closure, if it is an anonymous closure, i.e.
  /// an `ir.FunctionExpression`.
  final Local _closureEntity;

  /// The local variable that defines this closure, if it is a local function
  /// declaration.
  final ir.VariableDeclaration _closureEntityVariable;

  @override
  final Local thisLocal;

  @override
  final JClass closureClassEntity;

  final Map<ir.VariableDeclaration, JField> _variableToFieldMap;
  final Map<JTypeVariable, JField> _typeVariableToFieldMap;
  final Map<Local, JField> _localToFieldMap;
  Map<JField, Local> _fieldToLocalsMap;

  JsClosureClassInfo.internal(
      Iterable<ir.VariableDeclaration> localsUsedInTryOrSync,
      this.thisLocal,
      Map<ir.VariableDeclaration, migrated.JRecordField> boxedVariables,
      this.callMethod,
      this.signatureMethod,
      this._closureEntity,
      this._closureEntityVariable,
      this.closureClassEntity,
      this._variableToFieldMap,
      this._typeVariableToFieldMap,
      this._localToFieldMap)
      : super.internal(localsUsedInTryOrSync, thisLocal, boxedVariables);

  JsClosureClassInfo.fromScopeInfo(
      this.closureClassEntity,
      ir.FunctionNode closureSourceNode,
      Map<ir.VariableDeclaration, migrated.JRecordField> boxedVariables,
      KernelScopeInfo info,
      ClassEntity enclosingClass,
      this._closureEntity,
      this._closureEntityVariable,
      this.thisLocal)
      : _variableToFieldMap = {},
        _typeVariableToFieldMap = {},
        _localToFieldMap = {},
        super.from(boxedVariables, info, enclosingClass);

  factory JsClosureClassInfo.readFromDataSource(DataSourceReader source) {
    source.begin(tag);
    Iterable<ir.VariableDeclaration> localsUsedInTryOrSync =
        source.readTreeNodes<ir.VariableDeclaration>();
    Local thisLocal = source.readLocalOrNull();
    Map<ir.VariableDeclaration, migrated.JRecordField> boxedVariables =
        source.readTreeNodeMap<ir.VariableDeclaration, migrated.JRecordField>(
            () => source.readMember());
    JFunction callMethod = source.readMember();
    JSignatureMethod signatureMethod = source.readMemberOrNull();
    Local closureEntity = source.readLocalOrNull();
    ir.VariableDeclaration closureEntityVariable = source.readTreeNodeOrNull();
    JClass closureClassEntity = source.readClass();
    Map<ir.VariableDeclaration, JField> localToFieldMap =
        source.readTreeNodeMap<ir.VariableDeclaration, JField>(
            () => source.readMember());
    Map<JTypeVariable, JField> typeVariableToFieldMap = source
        .readTypeVariableMap<JTypeVariable, JField>(() => source.readMember());
    Map<Local, JField> thisLocalToFieldMap =
        source.readLocalMap(() => source.readMember());
    source.end(tag);
    if (boxedVariables.isEmpty) boxedVariables = const {};
    if (localToFieldMap.isEmpty) localToFieldMap = const {};
    return JsClosureClassInfo.internal(
        localsUsedInTryOrSync,
        thisLocal,
        boxedVariables,
        callMethod,
        signatureMethod,
        closureEntity,
        closureEntityVariable,
        closureClassEntity,
        localToFieldMap,
        typeVariableToFieldMap,
        thisLocalToFieldMap);
  }

  @override
  void writeToDataSink(DataSinkWriter sink) {
    sink.writeEnum(ScopeInfoKind.closureRepresentationInfo);
    sink.begin(tag);
    sink.writeTreeNodes(_localsUsedInTryOrSync);
    sink.writeLocalOrNull(thisLocal);
    sink.writeTreeNodeMap(_boxedVariables, sink.writeMember);
    sink.writeMember(callMethod);
    sink.writeMemberOrNull(signatureMethod);
    sink.writeLocalOrNull(_closureEntity);
    sink.writeTreeNodeOrNull(_closureEntityVariable);
    sink.writeClass(closureClassEntity);
    sink.writeTreeNodeMap(_variableToFieldMap, sink.writeMember);
    sink.writeTypeVariableMap(_typeVariableToFieldMap, sink.writeMember);
    sink.writeLocalMap(_localToFieldMap, sink.writeMember);
    sink.end(tag);
  }

  @override
  bool hasFieldForLocal(Local local) => _localToFieldMap.containsKey(local);

  @override
  void registerFieldForLocal(Local local, JField field) {
    assert(_fieldToLocalsMap == null);
    _localToFieldMap[local] = field;
  }

  @override
  void registerFieldForVariable(ir.VariableDeclaration node, JField field) {
    assert(_fieldToLocalsMap == null);
    _variableToFieldMap[node] = field;
  }

  @override
  bool hasFieldForTypeVariable(JTypeVariable typeVariable) =>
      _typeVariableToFieldMap.containsKey(typeVariable);

  @override
  void registerFieldForTypeVariable(JTypeVariable typeVariable, JField field) {
    assert(_fieldToLocalsMap == null);
    _typeVariableToFieldMap[typeVariable] = field;
  }

  @override
  void registerFieldForBoxedVariable(
      ir.VariableDeclaration node, JField field) {
    assert(_boxedVariablesCache == null);
    _boxedVariables[node] = field;
  }

  void _ensureFieldToLocalsMap(KernelToLocalsMap localsMap) {
    if (_fieldToLocalsMap == null) {
      _fieldToLocalsMap = {};
      _variableToFieldMap.forEach((ir.VariableDeclaration node, JField field) {
        _fieldToLocalsMap[field] = localsMap.getLocalVariable(node);
      });
      _typeVariableToFieldMap
          .forEach((TypeVariableEntity typeVariable, JField field) {
        _fieldToLocalsMap[field] =
            localsMap.getLocalTypeVariableEntity(typeVariable);
      });
      _localToFieldMap.forEach((Local local, JField field) {
        _fieldToLocalsMap[field] = local;
      });
      if (_fieldToLocalsMap.isEmpty) {
        _fieldToLocalsMap = const {};
      }
    }
  }

  @override
  List<Local> getCreatedFieldEntities(KernelToLocalsMap localsMap) {
    _ensureFieldToLocalsMap(localsMap);
    return _fieldToLocalsMap.values.toList();
  }

  @override
  Local getLocalForField(KernelToLocalsMap localsMap, FieldEntity field) {
    _ensureFieldToLocalsMap(localsMap);
    Local local = _fieldToLocalsMap[field];
    if (local == null) {
      failedAt(field, "No local for $field. Options: $_fieldToLocalsMap");
    }
    return local;
  }

  @override
  FieldEntity get thisFieldEntity => _localToFieldMap[thisLocal];

  @override
  void forEachFreeVariable(
      KernelToLocalsMap localsMap, f(Local variable, JField field)) {
    _ensureFieldToLocalsMap(localsMap);
    _ensureBoxedVariableCache(localsMap);
    _fieldToLocalsMap.forEach((JField field, Local local) {
      f(local, field);
    });
    _boxedVariablesCache.forEach(f);
  }

  @override
  bool get isClosure => true;

  @override
  Local getClosureEntity(KernelToLocalsMap localsMap) {
    return _closureEntityVariable != null
        ? localsMap.getLocalVariable(_closureEntityVariable)
        : _closureEntity;
  }
}

class RecordClassData implements JClassData {
  /// Tag used for identifying serialized [RecordClassData] objects in a
  /// debugging data stream.
  static const String tag = 'record-class-data';

  @override
  final ClassDefinition definition;

  @override
  final InterfaceType thisType;

  @override
  final OrderedTypeSet orderedTypeSet;

  @override
  final InterfaceType supertype;

  RecordClassData(
      this.definition, this.thisType, this.supertype, this.orderedTypeSet);

  factory RecordClassData.readFromDataSource(DataSourceReader source) {
    source.begin(tag);
    ClassDefinition definition = ClassDefinition.readFromDataSource(source);
    InterfaceType thisType = source.readDartType();
    InterfaceType supertype = source.readDartType();
    OrderedTypeSet orderedTypeSet = OrderedTypeSet.readFromDataSource(source);
    source.end(tag);
    return RecordClassData(definition, thisType, supertype, orderedTypeSet);
  }

  @override
  void writeToDataSink(DataSinkWriter sink) {
    sink.writeEnum(JClassDataKind.record);
    sink.begin(tag);
    definition.writeToDataSink(sink);
    sink.writeDartType(thisType);
    sink.writeDartType(supertype);
    orderedTypeSet.writeToDataSink(sink);
    sink.end(tag);
  }

  @override
  bool get isMixinApplication => false;

  @override
  bool get isEnumClass => false;

  @override
  FunctionType get callType => null;

  @override
  List<InterfaceType> get interfaces => const <InterfaceType>[];

  @override
  InterfaceType get mixedInType => null;

  @override
  InterfaceType get jsInteropType => thisType;

  @override
  InterfaceType get rawType => thisType;

  @override
  InterfaceType get instantiationToBounds => thisType;

  @override
  List<Variance> getVariances() => [];
}

class ClosureClassData extends RecordClassData {
  /// Tag used for identifying serialized [ClosureClassData] objects in a
  /// debugging data stream.
  static const String tag = 'closure-class-data';

  @override
  FunctionType callType;

  ClosureClassData(ClassDefinition definition, InterfaceType thisType,
      InterfaceType supertype, OrderedTypeSet orderedTypeSet)
      : super(definition, thisType, supertype, orderedTypeSet);

  factory ClosureClassData.readFromDataSource(DataSourceReader source) {
    source.begin(tag);
    ClassDefinition definition = ClassDefinition.readFromDataSource(source);
    InterfaceType thisType = source.readDartType();
    InterfaceType supertype = source.readDartType();
    OrderedTypeSet orderedTypeSet = OrderedTypeSet.readFromDataSource(source);
    FunctionType callType = source.readDartType();
    source.end(tag);
    return ClosureClassData(definition, thisType, supertype, orderedTypeSet)
      ..callType = callType;
  }

  @override
  void writeToDataSink(DataSinkWriter sink) {
    sink.writeEnum(JClassDataKind.closure);
    sink.begin(tag);
    definition.writeToDataSink(sink);
    sink.writeDartType(thisType);
    sink.writeDartType(supertype);
    orderedTypeSet.writeToDataSink(sink);
    sink.writeDartType(callType);
    sink.end(tag);
  }
}

class ClosureClassDefinition implements ClassDefinition {
  /// Tag used for identifying serialized [ClosureClassDefinition] objects in a
  /// debugging data stream.
  static const String tag = 'closure-class-definition';

  @override
  final SourceSpan location;

  ClosureClassDefinition(this.location);

  factory ClosureClassDefinition.readFromDataSource(DataSourceReader source) {
    source.begin(tag);
    SourceSpan location = source.readSourceSpan();
    source.end(tag);
    return ClosureClassDefinition(location);
  }

  @override
  void writeToDataSink(DataSinkWriter sink) {
    sink.writeEnum(ClassKind.closure);
    sink.begin(tag);
    sink.writeSourceSpan(location);
    sink.end(tag);
  }

  @override
  ClassKind get kind => ClassKind.closure;

  @override
  ir.Node get node =>
      throw UnsupportedError('ClosureClassDefinition.node for $location');

  @override
  String toString() => 'ClosureClassDefinition(kind:$kind,location:$location)';
}

abstract class ClosureMemberData implements JMemberData {
  @override
  final MemberDefinition definition;
  final InterfaceType memberThisType;

  ClosureMemberData(this.definition, this.memberThisType);

  @override
  StaticTypeCache get staticTypes {
    // The cached types are stored in the data for enclosing member.
    throw UnsupportedError("ClosureMemberData.staticTypes");
  }

  @override
  InterfaceType getMemberThisType(JsToElementMap elementMap) {
    return memberThisType;
  }
}

class ClosureFunctionData extends ClosureMemberData
    with FunctionDataTypeVariablesMixin, FunctionDataForEachParameterMixin
    implements FunctionData {
  /// Tag used for identifying serialized [ClosureFunctionData] objects in a
  /// debugging data stream.
  static const String tag = 'closure-function-data';

  final FunctionType functionType;
  @override
  ir.FunctionNode get functionNode => _functionNode.loaded();
  final Deferrable<ir.FunctionNode> _functionNode;
  @override
  final ClassTypeVariableAccess classTypeVariableAccess;

  ir.Member _memberContext;

  ClosureFunctionData(
      ClosureMemberDefinition definition,
      InterfaceType memberThisType,
      this.functionType,
      ir.FunctionNode functionNode,
      this.classTypeVariableAccess)
      : _functionNode = Deferrable.eager(functionNode),
        super(definition, memberThisType);

  ClosureFunctionData._deserialized(
      ClosureMemberDefinition definition,
      InterfaceType memberThisType,
      this.functionType,
      this._functionNode,
      this.classTypeVariableAccess)
      : super(definition, memberThisType);

  factory ClosureFunctionData.readFromDataSource(DataSourceReader source) {
    source.begin(tag);
    ClosureMemberDefinition definition =
        MemberDefinition.readFromDataSource(source);
    InterfaceType /*?*/ memberThisType =
        source.readDartTypeOrNull() as InterfaceType /*?*/;
    FunctionType functionType = source.readDartType();
    Deferrable<ir.FunctionNode> functionNode =
        source.readDeferrable(() => source.readTreeNode());
    ClassTypeVariableAccess classTypeVariableAccess =
        source.readEnum(ClassTypeVariableAccess.values);
    source.end(tag);
    return ClosureFunctionData._deserialized(definition, memberThisType,
        functionType, functionNode, classTypeVariableAccess);
  }

  @override
  void writeToDataSink(DataSinkWriter sink) {
    sink.writeEnum(JMemberDataKind.closureFunction);
    sink.begin(tag);
    definition.writeToDataSink(sink);
    sink.writeDartTypeOrNull(memberThisType);
    sink.writeDartType(functionType);
    sink.writeDeferrable(() => sink.writeTreeNode(functionNode));
    sink.writeEnum(classTypeVariableAccess);
    sink.end(tag);
  }

  @override
  ir.Member get memberContext {
    if (_memberContext == null) {
      ir.TreeNode parent = functionNode;
      while (parent is! ir.Member) {
        parent = parent.parent;
      }
      _memberContext = parent;
    }
    return _memberContext;
  }

  @override
  FunctionType getFunctionType(IrToElementMap elementMap) {
    return functionType;
  }
}

class ClosureFieldData extends ClosureMemberData implements JFieldData {
  /// Tag used for identifying serialized [ClosureFieldData] objects in a
  /// debugging data stream.
  static const String tag = 'closure-field-data';

  DartType _type;

  ClosureFieldData(MemberDefinition definition, InterfaceType memberThisType)
      : super(definition, memberThisType);

  factory ClosureFieldData.readFromDataSource(DataSourceReader source) {
    source.begin(tag);
    MemberDefinition definition = MemberDefinition.readFromDataSource(source);
    InterfaceType /*?*/ memberThisType =
        source.readDartTypeOrNull() as InterfaceType /*?*/;
    source.end(tag);
    return ClosureFieldData(definition, memberThisType);
  }

  @override
  void writeToDataSink(DataSinkWriter sink) {
    sink.writeEnum(JMemberDataKind.closureField);
    sink.begin(tag);
    definition.writeToDataSink(sink);
    sink.writeDartTypeOrNull(memberThisType);
    sink.end(tag);
  }

  @override
  DartType getFieldType(IrToElementMap elementMap) {
    if (_type != null) return _type;
    ir.TreeNode sourceNode = definition.node;
    ir.DartType type;
    if (sourceNode is ir.Class) {
      type = sourceNode.getThisType(
          elementMap.coreTypes, sourceNode.enclosingLibrary.nonNullable);
    } else if (sourceNode is ir.VariableDeclaration) {
      type = sourceNode.type;
    } else if (sourceNode is ir.Field) {
      type = sourceNode.type;
    } else if (sourceNode is ir.TypeLiteral) {
      type = sourceNode.type;
    } else if (sourceNode is ir.Typedef) {
      type = sourceNode.type;
    } else if (sourceNode is ir.TypeParameter) {
      type = sourceNode.bound;
    } else {
      failedAt(
          definition.location,
          'Unexpected node type ${sourceNode} in '
          'ClosureFieldData.getFieldType');
    }
    return _type = elementMap.getDartType(type);
  }

  @override
  ClassTypeVariableAccess get classTypeVariableAccess =>
      ClassTypeVariableAccess.none;
}

class RecordContainerDefinition implements ClassDefinition {
  /// Tag used for identifying serialized [RecordContainerDefinition] objects in
  /// a debugging data stream.
  static const String tag = 'record-definition';

  @override
  final SourceSpan location;

  RecordContainerDefinition(this.location);

  factory RecordContainerDefinition.readFromDataSource(
      DataSourceReader source) {
    source.begin(tag);
    SourceSpan location = source.readSourceSpan();
    source.end(tag);
    return RecordContainerDefinition(location);
  }

  @override
  void writeToDataSink(DataSinkWriter sink) {
    sink.writeEnum(ClassKind.record);
    sink.begin(tag);
    sink.writeSourceSpan(location);
    sink.end(tag);
  }

  @override
  ClassKind get kind => ClassKind.record;

  @override
  ir.Node get node =>
      throw UnsupportedError('RecordContainerDefinition.node for $location');

  @override
  String toString() =>
      'RecordContainerDefinition(kind:$kind,location:$location)';
}

abstract class ClosureRtiNeed {
  bool classNeedsTypeArguments(ClassEntity cls);

  bool methodNeedsTypeArguments(FunctionEntity method);

  bool methodNeedsSignature(MemberEntity method);

  bool localFunctionNeedsTypeArguments(ir.LocalFunction node);

  bool localFunctionNeedsSignature(ir.LocalFunction node);

  bool selectorNeedsTypeArguments(Selector selector);

  bool instantiationNeedsTypeArguments(
      FunctionType functionType, int typeArgumentCount);
}
