//===--- DependencyGraphBuilder.swift -------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@_implementationOnly import CSwiftScan

internal extension SwiftScan {
  /// From a reference to a binary-format dependency graph returned by libSwiftScan,
  /// construct an instance of an `InterModuleDependencyGraph`.
  func constructGraph(from scannerGraphRef: swiftscan_dependency_graph_t) throws
  -> InterModuleDependencyGraph {
    let mainModuleNameRef =
      api.swiftscan_dependency_graph_get_main_module_name(scannerGraphRef)
    let mainModuleName = try toSwiftString(mainModuleNameRef)

    let dependencySetRefOrNull = api.swiftscan_dependency_graph_get_dependencies(scannerGraphRef)
    guard let dependencySetRef = dependencySetRefOrNull else {
      throw DependencyScanningError.missingField("dependency_graph.dependencies")
    }

    var resultGraph = InterModuleDependencyGraph(mainModuleName: mainModuleName)
    // Turn the `swiftscan_dependency_set_t` into an array of `swiftscan_dependency_info_t`
    // references we can iterate through in order to construct `ModuleInfo` objects.
    let moduleRefArrray = Array(UnsafeBufferPointer(start: dependencySetRef.pointee.modules,
                                                    count: Int(dependencySetRef.pointee.count)))
    for moduleRefOrNull in moduleRefArrray {
      guard let moduleRef = moduleRefOrNull else {
        throw DependencyScanningError.missingField("dependency_set_t.modules[_]")
      }
      let (moduleId, moduleInfo) = try constructModuleInfo(from: moduleRef)
      resultGraph.modules[moduleId] = moduleInfo
    }

    return resultGraph
  }

  /// From a reference to a binary-format dependency graph collection returned by libSwiftScan batch scan query,
  /// corresponding to the specified batch scan input (`BatchScanModuleInfo`), construct instances of
  /// `InterModuleDependencyGraph` for each result.
  func constructBatchResultGraphs(for batchInfos: [BatchScanModuleInfo],
                                  from batchResultRef: swiftscan_batch_scan_result_t) throws
  -> [ModuleDependencyId: [InterModuleDependencyGraph]] {
    var resultMap: [ModuleDependencyId: [InterModuleDependencyGraph]] = [:]
    let resultGraphRefArray = Array(UnsafeBufferPointer(start: batchResultRef.results,
                                                        count: Int(batchResultRef.count)))
    // Note, respective indeces of the batch scan input and the returned result must be aligned.
    for (index, resultGraphRefOrNull) in resultGraphRefArray.enumerated() {
      guard let resultGraphRef = resultGraphRefOrNull else {
        throw DependencyScanningError.dependencyScanFailed
      }
      let decodedGraph = try constructGraph(from: resultGraphRef)

      let moduleId: ModuleDependencyId
      switch batchInfos[index] {
        case .swift(let swiftModuleBatchScanInfo):
          moduleId = .swift(swiftModuleBatchScanInfo.swiftModuleName)
        case .clang(let clangModuleBatchScanInfo):
          moduleId = .clang(clangModuleBatchScanInfo.clangModuleName)
      }
      // Update the map with either yet another graph or create an entry for this module
      if resultMap[moduleId] != nil {
        resultMap[moduleId]!.append(decodedGraph)
      } else {
        resultMap[moduleId] = [decodedGraph]
      }
    }
    return resultMap
  }

  /// From a reference to a binary-format import set returned by libSwiftScan prescan query,
  /// construct instances of `String` for each import
  func constructImportSet(from scannerImportSetRef: swiftscan_import_set_t) throws -> [String] {
    guard let importsRef = api.swiftscan_import_set_get_imports(scannerImportSetRef) else {
      fatalError("Prototypes don't always work.")
    }
    return try toSwiftStringArray(importsRef.pointee)
  }
}

private extension SwiftScan {
  /// From a reference to a binary-format module dependency module info returned by libSwiftScan,
  /// construct an instance of an `ModuleInfo` as used by the driver
  func constructModuleInfo(from moduleInfoRef: swiftscan_dependency_info_t)
  throws -> (ModuleDependencyId, ModuleInfo) {
    // Decode the module name and module kind
    let encodedModuleName =
      try toSwiftString(api.swiftscan_module_info_get_module_name(moduleInfoRef))
    let moduleId = try decodeModuleNameAndKind(from: encodedModuleName)

    // Decode module path and source file locations
    let modulePathStr = try toSwiftString(api.swiftscan_module_info_get_module_path(moduleInfoRef))
    let modulePath = TextualVirtualPath(path: try VirtualPath(path: modulePathStr))
    let sourceFiles: [String]?
    if let sourceFilesSetRef = api.swiftscan_module_info_get_source_files(moduleInfoRef) {
      sourceFiles = try toSwiftStringArray(sourceFilesSetRef.pointee)
    } else {
      sourceFiles = nil
    }

    // Decode all dependencies of this module
    let directDependencies: [ModuleDependencyId]?
    if let encodedDirectDepsRef = api.swiftscan_module_info_get_direct_dependencies(moduleInfoRef) {
      let encodedDirectDependencies = try toSwiftStringArray(encodedDirectDepsRef.pointee)
      directDependencies =
        try encodedDirectDependencies.map { try decodeModuleNameAndKind(from: $0) }
    } else {
      directDependencies = nil
    }

    guard let moduleDetailsRef = api.swiftscan_module_info_get_details(moduleInfoRef) else {
      throw DependencyScanningError.missingField("modules[\(moduleId)].details")
    }
    let details = try constructModuleDetails(from: moduleDetailsRef)

    return (moduleId, ModuleInfo(modulePath: modulePath, sourceFiles: sourceFiles,
                                 directDependencies: directDependencies,
                                 details: details))
  }

  /// From a reference to a binary-format module info details object info returned by libSwiftScan,
  /// construct an instance of an `ModuleInfo`.Details as used by the driver.
  /// The object returned by libSwiftScan is a union so ensure to execute dependency-specific queries.
  func constructModuleDetails(from moduleDetailsRef: swiftscan_module_details_t)
  throws -> ModuleInfo.Details {
    let moduleKind = api.swiftscan_module_detail_get_kind(moduleDetailsRef)
    switch moduleKind {
      case SWIFTSCAN_DEPENDENCY_INFO_SWIFT_TEXTUAL:
        return .swift(try constructSwiftTextualModuleDetails(from: moduleDetailsRef))
      case SWIFTSCAN_DEPENDENCY_INFO_SWIFT_BINARY:
        return .swiftPrebuiltExternal(try constructSwiftBinaryModuleDetails(from: moduleDetailsRef))
      case SWIFTSCAN_DEPENDENCY_INFO_SWIFT_PLACEHOLDER:
        return .swiftPlaceholder(try constructPlaceholderModuleDetails(from: moduleDetailsRef))
      case SWIFTSCAN_DEPENDENCY_INFO_CLANG:
        return .clang(try constructClangModuleDetails(from: moduleDetailsRef))
      default:
        throw DependencyScanningError.unsupportedDependencyDetailsKind(Int(moduleKind.rawValue))
    }
  }

  /// Construct a `SwiftModuleDetails` from a `swiftscan_module_details_t` reference
  func constructSwiftTextualModuleDetails(from moduleDetailsRef: swiftscan_module_details_t)
  throws -> SwiftModuleDetails {
    let moduleInterfacePath =
      try getOptionalPathDetail(from: moduleDetailsRef,
                                using: api.swiftscan_swift_textual_detail_get_module_interface_path)
    let compiledModuleCandidates =
      try getOptionalPathArrayDetail(from: moduleDetailsRef,
                                     using: api.swiftscan_swift_textual_detail_get_compiled_module_candidates)
    let bridgingHeaderPath =
      try getOptionalPathDetail(from: moduleDetailsRef,
                                using: api.swiftscan_swift_textual_detail_get_bridging_header_path)
    let bridgingSourceFiles =
      try getOptionalPathArrayDetail(from: moduleDetailsRef,
                                     using: api.swiftscan_swift_textual_detail_get_bridging_source_files)
    let commandLine =
      try getOptionalStringArrayDetail(from: moduleDetailsRef,
                                       using: api.swiftscan_swift_textual_detail_get_command_line)
    let extraPcmArgs =
      try getStringArrayDetail(from: moduleDetailsRef,
                               using: api.swiftscan_swift_textual_detail_get_extra_pcm_args,
                               fieldName: "extraPCMArgs")
    let isFramework = api.swiftscan_swift_textual_detail_get_is_framework(moduleDetailsRef)
    return SwiftModuleDetails(moduleInterfacePath: moduleInterfacePath,
                              compiledModuleCandidates: compiledModuleCandidates,
                              bridgingHeaderPath: bridgingHeaderPath,
                              bridgingSourceFiles: bridgingSourceFiles,
                              commandLine: commandLine,
                              extraPcmArgs: extraPcmArgs,
                              isFramework: isFramework)
  }

  /// Construct a `SwiftPrebuiltExternalModuleDetails` from a `swiftscan_module_details_t` reference
  func constructSwiftBinaryModuleDetails(from moduleDetailsRef: swiftscan_module_details_t)
  throws -> SwiftPrebuiltExternalModuleDetails {
    let compiledModulePath =
      try getPathDetail(from: moduleDetailsRef,
                        using: api.swiftscan_swift_binary_detail_get_compiled_module_path,
                        fieldName: "swift_binary_detail.compiledModulePath")
    let moduleDocPath =
      try getOptionalPathDetail(from: moduleDetailsRef,
                                using: api.swiftscan_swift_binary_detail_get_module_doc_path)
    let moduleSourceInfoPath =
      try getOptionalPathDetail(from: moduleDetailsRef,
                                using: api.swiftscan_swift_binary_detail_get_module_source_info_path)
    return try SwiftPrebuiltExternalModuleDetails(compiledModulePath: compiledModulePath,
                                                  moduleDocPath: moduleDocPath,
                                                  moduleSourceInfoPath: moduleSourceInfoPath)
  }

  /// Construct a `SwiftPlaceholderModuleDetails` from a `swiftscan_module_details_t` reference
  func constructPlaceholderModuleDetails(from moduleDetailsRef: swiftscan_module_details_t)
  throws -> SwiftPlaceholderModuleDetails {
    let moduleDocPath =
      try getOptionalPathDetail(from: moduleDetailsRef,
                                using: api.swiftscan_swift_placeholder_detail_get_module_doc_path)
    let moduleSourceInfoPath =
      try getOptionalPathDetail(from: moduleDetailsRef,
                                using: api.swiftscan_swift_placeholder_detail_get_module_source_info_path)
    return SwiftPlaceholderModuleDetails(moduleDocPath: moduleDocPath,
                                         moduleSourceInfoPath: moduleSourceInfoPath)
  }

  /// Construct a `ClangModuleDetails` from a `swiftscan_module_details_t` reference
  func constructClangModuleDetails(from moduleDetailsRef: swiftscan_module_details_t)
  throws -> ClangModuleDetails {
    let moduleMapPath =
      try getPathDetail(from: moduleDetailsRef,
                        using: api.swiftscan_clang_detail_get_module_map_path,
                        fieldName: "clang_detail.moduleMapPath")
    let contextHash =
      try getStringDetail(from: moduleDetailsRef,
                          using: api.swiftscan_clang_detail_get_context_hash,
                          fieldName: "clang_detail.contextHash")
    let commandLine =
      try getStringArrayDetail(from: moduleDetailsRef,
                               using: api.swiftscan_clang_detail_get_command_line,
                               fieldName: "clang_detail.commandLine")

    return ClangModuleDetails(moduleMapPath: moduleMapPath,
                              dependenciesCapturedPCMArgs: nil,
                              contextHash: contextHash,
                              commandLine: commandLine)
  }
}

internal extension SwiftScan {
  /// Convert a `swiftscan_string_ref_t` reference to a Swfit `String`, assuming the reference is to a valid string
  /// (non-null)
  func toSwiftString(_ string_ref: swiftscan_string_ref_t) throws -> String {
    if string_ref.length == 0 {
      return ""
    }
    // If the string is of a positive length, the pointer cannot be null
    guard let dataPtr = string_ref.data else {
      throw DependencyScanningError.invalidStringPtr
    }
    return String(bytesNoCopy: UnsafeMutableRawPointer(mutating: dataPtr),
                  length: string_ref.length,
                  encoding: String.Encoding.utf8, freeWhenDone: false)!
  }

  /// Convert a `swiftscan_string_set_t` reference to a Swfit `[String]`, assuming the individual string references
  /// are to a valid strings (non-null)
  func toSwiftStringArray(_ string_set: swiftscan_string_set_t) throws -> [String] {
    var result: [String] = []
    let stringRefArrray = Array(UnsafeBufferPointer(start: string_set.strings,
                                                    count: Int(string_set.count)))
    for stringRef in stringRefArrray {
      result.append(try toSwiftString(stringRef))
    }
    return result
  }

  /// Convert a `swiftscan_string_set_t` reference to a Swfit `Set<String>`, assuming the individual string references
  /// are to a valid strings (non-null)
  func toSwiftStringSet(_ string_set: swiftscan_string_set_t) throws -> Set<String> {
    var result = Set<String>()
    let stringRefArrray = Array(UnsafeBufferPointer(start: string_set.strings,
                                                    count: Int(string_set.count)))
    for stringRef in stringRefArrray {
      result.insert(try toSwiftString(stringRef))
    }
    return result
  }
}

private extension SwiftScan {
  /// From a `swiftscan_module_details_t` reference, extract a `TextualVirtualPath?` detail using the specified API query
  func getOptionalPathDetail(from detailsRef: swiftscan_module_details_t,
                             using query: (swiftscan_module_details_t)
                              -> swiftscan_string_ref_t)
  throws -> TextualVirtualPath? {
    let strDetail = try getOptionalStringDetail(from: detailsRef, using: query)
    return strDetail != nil ? TextualVirtualPath(path: try VirtualPath(path: strDetail!)) : nil
  }

  /// From a `swiftscan_module_details_t` reference, extract a `String?` detail using the specified API query
  func getOptionalStringDetail(from detailsRef: swiftscan_module_details_t,
                               using query: (swiftscan_module_details_t)
                                -> swiftscan_string_ref_t)
  throws -> String? {
    let detailRef = query(detailsRef)
    guard detailRef.length != 0 else { return nil }
    assert(detailRef.data != nil)
    return try toSwiftString(detailRef)
  }

  /// From a `swiftscan_module_details_t` reference, extract a `TextualVirtualPath` detail using the specified API
  /// query, making sure the reference is to a non-null (and non-empty) path.
  func getPathDetail(from detailsRef: swiftscan_module_details_t,
                     using query: (swiftscan_module_details_t) -> swiftscan_string_ref_t,
                     fieldName: String)
  throws -> TextualVirtualPath {
    let strDetail = try getStringDetail(from: detailsRef, using: query, fieldName: fieldName)
    return TextualVirtualPath(path: try VirtualPath(path: strDetail))
  }

  /// From a `swiftscan_module_details_t` reference, extract a `String` detail using the specified API query,
  /// making sure the reference is to a non-null (and non-empty) string.
  func getStringDetail(from detailsRef: swiftscan_module_details_t,
                       using query: (swiftscan_module_details_t) -> swiftscan_string_ref_t,
                       fieldName: String) throws -> String {
    guard let result = try getOptionalStringDetail(from: detailsRef, using: query) else {
      throw DependencyScanningError.missingField(fieldName)
    }
    return result
  }

  /// From a `swiftscan_module_details_t` reference, extract a `[TextualVirtualPath]?` detail using the specified API
  /// query
  func getOptionalPathArrayDetail(from detailsRef: swiftscan_module_details_t,
  using query: (swiftscan_module_details_t)
    -> UnsafeMutablePointer<swiftscan_string_set_t>?)
  throws -> [TextualVirtualPath]? {
    guard let strArrDetail = try getOptionalStringArrayDetail(from: detailsRef, using: query) else {
      return nil
    }
    return try strArrDetail.map { TextualVirtualPath(path: try VirtualPath(path: $0)) }
  }

  /// From a `swiftscan_module_details_t` reference, extract a `[String]?` detail using the specified API query
  func getOptionalStringArrayDetail(from detailsRef: swiftscan_module_details_t,
                                    using query: (swiftscan_module_details_t)
                                      -> UnsafeMutablePointer<swiftscan_string_set_t>?)
  throws -> [String]? {
    guard let detailRef = query(detailsRef) else { return nil }
    return try toSwiftStringArray(detailRef.pointee)
  }

  /// From a `swiftscan_module_details_t` reference, extract a `[String]` detail using the specified API query,
  /// making sure individual string references are non-null (and non-empty) strings.
  func getStringArrayDetail(from detailsRef: swiftscan_module_details_t,
                            using query: (swiftscan_module_details_t)
                                      -> UnsafeMutablePointer<swiftscan_string_set_t>?,
                            fieldName: String) throws -> [String] {
    guard let result = try getOptionalStringArrayDetail(from: detailsRef, using: query) else {
      throw DependencyScanningError.missingField(fieldName)
    }
    return result
  }
}

private extension SwiftScan {
  /// Decode the module name returned by libSwiftScan into a `ModuleDependencyId`
  /// libSwiftScan encodes the module's name using the following scheme:
  /// `<module-kind>:<module-name>`
  /// where `module-kind` is one of:
  /// "swiftTextual"
  /// "swiftBinary"
  /// "swiftPlaceholder"
  /// "clang""
  func decodeModuleNameAndKind(from encodedName: String) throws -> ModuleDependencyId {
    switch encodedName {
      case _ where encodedName.starts(with: "swiftTextual:"):
        return .swift(String(encodedName.suffix(encodedName.count - "swiftTextual:".count)))
      case _ where encodedName.starts(with: "swiftBinary:"):
        return .swiftPrebuiltExternal(String(encodedName.suffix(encodedName.count - "swiftBinary:".count)))
      case _ where encodedName.starts(with: "swiftPlaceholder:"):
        return .swiftPlaceholder(String(encodedName.suffix(encodedName.count - "swiftPlaceholder:".count)))
      case _ where encodedName.starts(with: "clang:"):
        return .clang(String(encodedName.suffix(encodedName.count - "clang:".count)))
      default:
        throw DependencyScanningError.moduleNameDecodeFailure(encodedName)
    }
  }
}
