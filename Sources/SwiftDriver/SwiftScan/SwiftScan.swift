//===------------------------ SwiftScan.swift -----------------------------===//
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

import TSCUtility
import TSCBasic
import Foundation

public enum DependencyScanningError: Error, DiagnosticData {
  case missingRequiredSymbol(String)
  case dependencyScanFailed
  case failedToInstantiateScanner
  case missingField(String)
  case moduleNameDecodeFailure(String)
  case unsupportedDependencyDetailsKind(Int)
  case invalidStringPtr
  case scanningLibraryInvocationMismatch(AbsolutePath, AbsolutePath)
  case scanningLibraryNotFound(AbsolutePath)
  case argumentQueryFailed

  public var description: String {
    switch self {
      case .missingRequiredSymbol(let symbolName):
        return "libSwiftScan missing required symbol: '\(symbolName)'"
      case .dependencyScanFailed:
        return "libSwiftScan dependency scan query failed"
      case .failedToInstantiateScanner:
        return "libSwiftScan failed to create scanner instance"
      case .missingField(let fieldName):
        return "libSwiftScan scan result missing required field: `\(fieldName)`"
      case .moduleNameDecodeFailure(let encodedName):
        return "Failed to decode dependency module name: `\(encodedName)`"
      case .unsupportedDependencyDetailsKind(let kindRawValue):
        return "Dependency module details field kind not supported: `\(kindRawValue)`"
      case .invalidStringPtr:
        return "Dependency module details contains a corrupted string reference"
      case .scanningLibraryInvocationMismatch(let path1, let path2):
        return "Dependency Scanning library differs across driver invocations: \(path1.description) and \(path2.description)"
      case .scanningLibraryNotFound(let path):
        return "Dependency Scanning library not found at path: \(path)"
      case .argumentQueryFailed:
        return "libSwiftScan supported compiler argument query failed"
    }
  }
}

/// Wrapper for libSwiftScan, taking care of initialization, shutdown, and dispatching dependency scanning queries.
internal final class SwiftScan {
  /// The path to the libSwiftScan dylib.
  let path: AbsolutePath

  /// The handle to the dylib.
  let dylib: DLHandle

  /// Lock protecting private state.
  let lock: Lock = Lock()

  /// libSwiftScan API functions.
  let api: swiftscan_functions_t;

  /// Instance of a scanner, which maintains shared state across scan queries.
  let scanner: swiftscan_scanner_t;

  @_spi(Testing) public init(dylib path: AbsolutePath) throws {
    self.path = path
    #if os(Windows)
    self.dylib = try dlopen(path.pathString, mode: [])
    #else
    self.dylib = try dlopen(path.pathString, mode: [.lazy, .local, .first])
    #endif
    self.api = try swiftscan_functions_t(self.dylib)
    guard let scanner = api.swiftscan_scanner_create() else {
      throw DependencyScanningError.failedToInstantiateScanner
    }
    self.scanner = scanner
  }

  deinit {
    api.swiftscan_scanner_dispose(self.scanner)
    // FIXME: is it safe to dlclose() swiftscan? If so, do that here.
    // For now, let the handle leak.
    dylib.leak()
  }

  func scanDependencies(workingDirectory: AbsolutePath,
                        invocationCommand: [String]) throws -> InterModuleDependencyGraph {
    // Create and configure the scanner invocation
    let invocation = api.swiftscan_scan_invocation_create()
    defer { api.swiftscan_scan_invocation_dispose(invocation) }
    api.swiftscan_scan_invocation_set_working_directory(invocation,
                                                        workingDirectory
                                                          .description
                                                          .cString(using: String.Encoding.utf8))
    withArrayOfCStrings(invocationCommand) { invocationStringArray in
      api.swiftscan_scan_invocation_set_argv(invocation,
                                             Int32(invocationCommand.count),
                                             invocationStringArray)
    }

    let graphRefOrNull = api.swiftscan_dependency_graph_create(scanner, invocation)
    guard let graphRef = graphRefOrNull else {
      throw DependencyScanningError.dependencyScanFailed
    }

    let dependencyGraph = try constructGraph(from: graphRef)
    // Free the memory allocated for the in-memory representation of the dependency
    // graph returned by the scanner, now that we have translated it into an
    // `InterModuleDependencyGraph`.
    api.swiftscan_dependency_graph_dispose(graphRef)
    return dependencyGraph
  }

  func batchScanDependencies(workingDirectory: AbsolutePath,
                             invocationCommand: [String],
                             batchInfos: [BatchScanModuleInfo])
  throws -> [ModuleDependencyId: [InterModuleDependencyGraph]] {
    // Create and configure the scanner invocation
    let invocationRef = api.swiftscan_scan_invocation_create()
    defer { api.swiftscan_scan_invocation_dispose(invocationRef) }
    api.swiftscan_scan_invocation_set_working_directory(invocationRef,
                                                        workingDirectory
                                                          .description
                                                          .cString(using: String.Encoding.utf8))
    withArrayOfCStrings(invocationCommand) { invocationStringArray in
      api.swiftscan_scan_invocation_set_argv(invocationRef,
                                             Int32(invocationCommand.count),
                                             invocationStringArray)
    }

    // Create and populate a batch scan input `swiftscan_batch_scan_input_t`
    let moduleEntriesPtr =
      UnsafeMutablePointer<swiftscan_batch_scan_entry_t?>.allocate(capacity: batchInfos.count)
    for (index, batchEntryInfo) in batchInfos.enumerated() {
      // Create and populate an individual `swiftscan_batch_scan_entry_t`
      let entryRef = api.swiftscan_batch_scan_entry_create()
      switch batchEntryInfo {
        case .clang(let clangEntryInfo):
          api.swiftscan_batch_scan_entry_set_module_name(entryRef,
                                                     clangEntryInfo.clangModuleName
                                                      .cString(using: String.Encoding.utf8))
          api.swiftscan_batch_scan_entry_set_is_swift(entryRef, false)
          api.swiftscan_batch_scan_entry_set_arguments(entryRef, clangEntryInfo.arguments
                                                        .cString(using: String.Encoding.utf8))
        case .swift(let swiftEntryInfo):
          api.swiftscan_batch_scan_entry_set_module_name(entryRef,
                                                         swiftEntryInfo.swiftModuleName
                                                          .cString(using: String.Encoding.utf8))
          api.swiftscan_batch_scan_entry_set_is_swift(entryRef, true)
      }
      (moduleEntriesPtr + index).initialize(to: entryRef)
    }
    let inputRef = api.swiftscan_batch_scan_input_create()
    // Disposing of the input frees memory of the contained entries, as well.
    defer { api.swiftscan_batch_scan_input_dispose(inputRef) }
    api.swiftscan_batch_scan_input_set_modules(inputRef, Int32(batchInfos.count),
                                               moduleEntriesPtr)

    let batchResultRefOrNull = api.swiftscan_batch_scan_result_create(scanner,
                                                                      inputRef,
                                                                      invocationRef)
    guard let batchResultRef = batchResultRefOrNull else {
      throw DependencyScanningError.dependencyScanFailed
    }
    // Translate `swiftscan_batch_scan_result_t`
    // into `[ModuleDependencyId: [InterModuleDependencyGraph]]`
    let resultGraphMap = try constructBatchResultGraphs(for: batchInfos,
                                                        from: batchResultRef.pointee)
    // Free the memory allocated for the in-memory representation of the batch scan
    // result, now that we have translated it.
    api.swiftscan_batch_scan_result_dispose(batchResultRefOrNull)
    return resultGraphMap
  }

  func prescanDependencies(workingDirectory: AbsolutePath,
                           invocationCommand: [String]) throws -> [String] {
    // Create and configure the scanner invocation
    let invocation = api.swiftscan_scan_invocation_create()
    defer { api.swiftscan_scan_invocation_dispose(invocation) }
    api.swiftscan_scan_invocation_set_working_directory(invocation,
                                                        workingDirectory
                                                          .description
                                                          .cString(using: String.Encoding.utf8))
    withArrayOfCStrings(invocationCommand) { invocationStringArray in
      api.swiftscan_scan_invocation_set_argv(invocation,
                                             Int32(invocationCommand.count),
                                             invocationStringArray)
    }

    let importsRefOrNull = api.swiftscan_import_set_create(scanner, invocation)
    guard let importsRef = importsRefOrNull else {
      throw DependencyScanningError.dependencyScanFailed
    }

    let imports = try constructImportSet(from: importsRef)
    // Free the memory allocated for the in-memory representation of the import set
    // returned by the scanner, now that we have translated it
    api.swiftscan_import_set_dispose(importsRef)
    return imports
  }

  @_spi(Testing) public func canQuerySupportedArguments() -> Bool {
    return api.swiftscan_compiler_supported_arguments_query != nil &&
           api.swiftscan_string_set_dispose != nil
  }

  @_spi(Testing) public func querySupportedArguments() throws -> Set<String> {
    precondition(canQuerySupportedArguments())
    if let queryResultStrings = api.swiftscan_compiler_supported_arguments_query!() {
      defer { api.swiftscan_string_set_dispose!(queryResultStrings) }
      return try toSwiftStringSet(queryResultStrings.pointee)
    } else {
      throw DependencyScanningError.argumentQueryFailed
    }
  }
}

// Used for testing purposes only
@_spi(Testing) public extension Driver {
  func querySupportedArgumentsForTest() throws -> Set<String>? {
    // If a capable libSwiftScan is found, manually ensure we can get the supported arguments
    let scanLibPath = try Self.getScanLibPath(of: toolchain,
                                              hostTriple: hostTriple,
                                              env: env)
    if fileSystem.exists(scanLibPath) {
      let libSwiftScanInstance = try SwiftScan(dylib: scanLibPath)
      if libSwiftScanInstance.canQuerySupportedArguments() {
        return try libSwiftScanInstance.querySupportedArguments()
      }
    }
    return nil
  }
}

private extension swiftscan_functions_t {
  init(_ swiftscan: DLHandle) throws {
    self.init()

    // MARK: Optional Methods
    // Future optional methods can be queried here
    func loadOptional<T>(_ symbol: String) throws -> T? {
      guard let sym: T = dlsym(swiftscan, symbol: symbol) else {
        return nil
      }
      return sym
    }
    self.swiftscan_string_set_dispose =
      try loadOptional("swiftscan_string_set_dispose")
    self.swiftscan_compiler_supported_arguments_query =
      try loadOptional("swiftscan_compiler_supported_arguments_query")
    self.swiftscan_compiler_supported_features_query =
      try loadOptional("swiftscan_compiler_supported_features_query")

    // MARK: Required Methods
    func loadRequired<T>(_ symbol: String) throws -> T {
      guard let sym: T = dlsym(swiftscan, symbol: symbol) else {
        throw DependencyScanningError.missingRequiredSymbol(symbol)
      }
      return sym
    }

    self.swiftscan_scanner_create =
      try loadRequired("swiftscan_scanner_create")
    self.swiftscan_scanner_dispose =
      try loadRequired("swiftscan_scanner_dispose")
    self.swiftscan_scan_invocation_get_working_directory =
      try loadRequired("swiftscan_scan_invocation_get_working_directory")
    self.swiftscan_scan_invocation_set_argv =
      try loadRequired("swiftscan_scan_invocation_set_argv")
    self.swiftscan_scan_invocation_set_working_directory =
      try loadRequired("swiftscan_scan_invocation_set_working_directory")
    self.swiftscan_scan_invocation_create =
      try loadRequired("swiftscan_scan_invocation_create")
    self.swiftscan_import_set_get_imports =
      try loadRequired("swiftscan_import_set_get_imports")
    self.swiftscan_batch_scan_entry_create =
      try loadRequired("swiftscan_batch_scan_entry_create")
    self.swiftscan_batch_scan_entry_get_is_swift =
      try loadRequired("swiftscan_batch_scan_entry_get_is_swift")
    self.swiftscan_batch_scan_entry_get_arguments =
      try loadRequired("swiftscan_batch_scan_entry_get_arguments")
    self.swiftscan_batch_scan_entry_get_module_name =
      try loadRequired("swiftscan_batch_scan_entry_get_module_name")
    self.swiftscan_batch_scan_entry_set_is_swift =
      try loadRequired("swiftscan_batch_scan_entry_set_is_swift")
    self.swiftscan_batch_scan_entry_set_arguments =
      try loadRequired("swiftscan_batch_scan_entry_set_arguments")
    self.swiftscan_batch_scan_entry_set_module_name =
      try loadRequired("swiftscan_batch_scan_entry_set_module_name")
    self.swiftscan_batch_scan_input_set_modules =
      try loadRequired("swiftscan_batch_scan_input_set_modules")
    self.swiftscan_batch_scan_input_create =
      try loadRequired("swiftscan_batch_scan_input_create")
    self.swiftscan_clang_detail_get_command_line =
      try loadRequired("swiftscan_clang_detail_get_command_line")
    self.swiftscan_clang_detail_get_context_hash =
      try loadRequired("swiftscan_clang_detail_get_context_hash")
    self.swiftscan_clang_detail_get_module_map_path =
      try loadRequired("swiftscan_clang_detail_get_module_map_path")
    self.swiftscan_swift_placeholder_detail_get_module_source_info_path =
      try loadRequired("swiftscan_swift_placeholder_detail_get_module_source_info_path")
    self.swiftscan_swift_placeholder_detail_get_module_doc_path =
      try loadRequired("swiftscan_swift_placeholder_detail_get_module_doc_path")
    self.swiftscan_swift_placeholder_detail_get_compiled_module_path =
      try loadRequired("swiftscan_swift_placeholder_detail_get_compiled_module_path")
    self.swiftscan_swift_binary_detail_get_module_source_info_path =
      try loadRequired("swiftscan_swift_binary_detail_get_module_source_info_path")
    self.swiftscan_swift_binary_detail_get_module_doc_path =
      try loadRequired("swiftscan_swift_binary_detail_get_module_doc_path")
    self.swiftscan_swift_binary_detail_get_compiled_module_path =
      try loadRequired("swiftscan_swift_binary_detail_get_compiled_module_path")
    self.swiftscan_swift_textual_detail_get_is_framework =
      try loadRequired("swiftscan_swift_textual_detail_get_is_framework")
    self.swiftscan_swift_textual_detail_get_context_hash =
      try loadRequired("swiftscan_swift_textual_detail_get_context_hash")
    self.swiftscan_dependency_graph_get_main_module_name =
      try loadRequired("swiftscan_dependency_graph_get_main_module_name")
    self.swiftscan_dependency_graph_get_dependencies =
      try loadRequired("swiftscan_dependency_graph_get_dependencies")
    self.swiftscan_module_info_get_module_name =
      try loadRequired("swiftscan_module_info_get_module_name")
    self.swiftscan_module_info_get_module_path =
      try loadRequired("swiftscan_module_info_get_module_path")
    self.swiftscan_module_info_get_source_files =
      try loadRequired("swiftscan_module_info_get_source_files")
    self.swiftscan_module_info_get_direct_dependencies =
      try loadRequired("swiftscan_module_info_get_direct_dependencies")
    self.swiftscan_module_info_get_details =
      try loadRequired("swiftscan_module_info_get_details")
    self.swiftscan_module_detail_get_kind =
      try loadRequired("swiftscan_module_detail_get_kind")
    self.swiftscan_swift_textual_detail_get_module_interface_path =
      try loadRequired("swiftscan_swift_textual_detail_get_module_interface_path")
    self.swiftscan_swift_textual_detail_get_compiled_module_candidates =
      try loadRequired("swiftscan_swift_textual_detail_get_compiled_module_candidates")
    self.swiftscan_swift_textual_detail_get_bridging_header_path =
      try loadRequired("swiftscan_swift_textual_detail_get_bridging_header_path")
    self.swiftscan_swift_textual_detail_get_bridging_source_files =
      try loadRequired("swiftscan_swift_textual_detail_get_bridging_source_files")
    self.swiftscan_swift_textual_detail_get_bridging_module_dependencies =
      try loadRequired("swiftscan_swift_textual_detail_get_bridging_module_dependencies")
    self.swiftscan_swift_textual_detail_get_command_line =
      try loadRequired("swiftscan_swift_textual_detail_get_command_line")
    self.swiftscan_swift_textual_detail_get_extra_pcm_args =
      try loadRequired("swiftscan_swift_textual_detail_get_extra_pcm_args")
    self.swiftscan_scan_invocation_get_argc =
      try loadRequired("swiftscan_scan_invocation_get_argc")
    self.swiftscan_scan_invocation_get_argv =
      try loadRequired("swiftscan_scan_invocation_get_argv")
    self.swiftscan_dependency_graph_dispose =
      try loadRequired("swiftscan_dependency_graph_dispose")
    self.swiftscan_import_set_dispose =
      try loadRequired("swiftscan_import_set_dispose")
    self.swiftscan_batch_scan_entry_dispose =
      try loadRequired("swiftscan_batch_scan_entry_dispose")
    self.swiftscan_batch_scan_input_dispose =
      try loadRequired("swiftscan_batch_scan_input_dispose")
    self.swiftscan_batch_scan_result_dispose =
      try loadRequired("swiftscan_batch_scan_result_dispose")
    self.swiftscan_scan_invocation_dispose =
      try loadRequired("swiftscan_scan_invocation_dispose")
    self.swiftscan_dependency_graph_create =
      try loadRequired("swiftscan_dependency_graph_create")
    self.swiftscan_batch_scan_result_create =
      try loadRequired("swiftscan_batch_scan_result_create")
    self.swiftscan_import_set_create =
      try loadRequired("swiftscan_import_set_create")
  }
}

// TODO: Move to TSC?
/// Perform an  `action` passing it a `const char **` constructed out of `[String]`
func withArrayOfCStrings(_ strings: [String],
                         _ action:  (UnsafeMutablePointer<UnsafePointer<Int8>?>?) -> Void)
{
  let cstrings = strings.map { strdup($0) } + [nil]
  let unsafeCStrings = cstrings.map { UnsafePointer($0) }
  let _ = unsafeCStrings.withUnsafeBufferPointer {
    action(UnsafeMutablePointer(mutating: $0.baseAddress))
  }
  for ptr in cstrings { free(ptr) }
}
