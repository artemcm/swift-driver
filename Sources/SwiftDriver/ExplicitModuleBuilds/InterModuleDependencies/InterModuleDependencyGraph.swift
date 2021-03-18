//===--------------- InterModuleDependencyGraph.swift ---------------------===//
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
import Foundation
import TSCBasic

/// A map from a module identifier to its info
public typealias ModuleInfoMap = [ModuleDependencyId: ModuleInfo]

public enum ModuleDependencyId: Hashable {
  case swift(String)
  case swiftPlaceholder(String)
  case swiftPrebuiltExternal(String)
  case clang(String)

  public var moduleName: String {
    switch self {
    case .swift(let name): return name
    case .swiftPlaceholder(let name): return name
    case .swiftPrebuiltExternal(let name): return name
    case .clang(let name): return name
    }
  }
}

extension ModuleDependencyId: Codable {
  enum CodingKeys: CodingKey {
    case swift
    case swiftPlaceholder
    case swiftPrebuiltExternal
    case clang
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      let moduleName =  try container.decode(String.self, forKey: .swift)
      self = .swift(moduleName)
    } catch {
      do {
        let moduleName =  try container.decode(String.self, forKey: .swiftPlaceholder)
        self = .swiftPlaceholder(moduleName)
      } catch {
        do {
          let moduleName =  try container.decode(String.self, forKey: .swiftPrebuiltExternal)
          self = .swiftPrebuiltExternal(moduleName)
        } catch {
          let moduleName =  try container.decode(String.self, forKey: .clang)
          self = .clang(moduleName)
        }
      }
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
      case .swift(let moduleName):
        try container.encode(moduleName, forKey: .swift)
      case .swiftPlaceholder(let moduleName):
        try container.encode(moduleName, forKey: .swiftPlaceholder)
      case .swiftPrebuiltExternal(let moduleName):
        try container.encode(moduleName, forKey: .swiftPrebuiltExternal)
      case .clang(let moduleName):
        try container.encode(moduleName, forKey: .clang)
    }
  }
}

/// Bridging header
public struct BridgingHeader: Codable {
  var path: TextualVirtualPath
  var sourceFiles: [TextualVirtualPath]
  var moduleDependencies: [String]
}

/// Details specific to Swift modules.
public struct SwiftModuleDetails: Codable {
  /// The module interface from which this module was built, if any.
  public var moduleInterfacePath: TextualVirtualPath?

  /// The paths of potentially ready-to-use compiled modules for the interface.
  public var compiledModuleCandidates: [TextualVirtualPath]?

  /// The bridging header, if any.
  public var bridgingHeaderPath: TextualVirtualPath?

  /// The source files referenced by the bridging header.
  public var bridgingSourceFiles: [TextualVirtualPath]? = []

  /// Options to the compile command
  public var commandLine: [String]? = []

  /// To build a PCM to be used by this Swift module, we need to append these
  /// arguments to the generic PCM build arguments reported from the dependency
  /// graph.
  public var extraPcmArgs: [String]

  /// A flag to indicate whether or not this module is a framework.
  public var isFramework: Bool
}

/// Details specific to Swift placeholder dependencies.
public struct SwiftPlaceholderModuleDetails: Codable {
  /// The path to the .swiftModuleDoc file.
  var moduleDocPath: TextualVirtualPath?

  /// The path to the .swiftSourceInfo file.
  var moduleSourceInfoPath: TextualVirtualPath?
}

/// Details specific to Swift externally-pre-built modules.
public struct SwiftPrebuiltExternalModuleDetails: Codable {
  /// The path to the already-compiled module that must be used instead of
  /// generating a job to build this module.
  public var compiledModulePath: TextualVirtualPath

  /// The path to the .swiftModuleDoc file.
  public var moduleDocPath: TextualVirtualPath?

  /// The path to the .swiftSourceInfo file.
  public var moduleSourceInfoPath: TextualVirtualPath?

  public init(compiledModulePath: TextualVirtualPath,
              moduleDocPath: TextualVirtualPath? = nil,
              moduleSourceInfoPath: TextualVirtualPath? = nil) throws {
    self.compiledModulePath = compiledModulePath
    self.moduleDocPath = moduleDocPath
    self.moduleSourceInfoPath = moduleSourceInfoPath
  }
}

/// Details specific to Clang modules.
public struct ClangModuleDetails: Codable {
  /// The path to the module map used to build this module.
  public var moduleMapPath: TextualVirtualPath

  /// Set of PCM Arguments of depending modules which
  /// are covered by the directDependencies info of this module
  public var dependenciesCapturedPCMArgs: Set<[String]>?

  /// clang-generated context hash
  public var contextHash: String

  /// Options to the compile command
  public var commandLine: [String] = []

  public init(moduleMapPath: TextualVirtualPath,
              dependenciesCapturedPCMArgs: Set<[String]>?,
              contextHash: String,
              commandLine: [String]) {
    self.moduleMapPath = moduleMapPath
    self.dependenciesCapturedPCMArgs = dependenciesCapturedPCMArgs
    self.contextHash = contextHash
    self.commandLine = commandLine
  }
}

public struct ModuleInfo: Codable {
  /// The path for the module.
  public var modulePath: TextualVirtualPath

  /// The source files used to build this module.
  public var sourceFiles: [String]?

  /// The set of direct module dependencies of this module.
  public var directDependencies: [ModuleDependencyId]?

  /// Specific details of a particular kind of module.
  public var details: Details

  /// Specific details of a particular kind of module.
  public enum Details {
    /// Swift modules may be built from a module interface, and may have
    /// a bridging header.
    case swift(SwiftModuleDetails)

    /// Swift placeholder modules carry additional details that specify their
    /// module doc path and source info paths.
    case swiftPlaceholder(SwiftPlaceholderModuleDetails)

    /// Swift externally-prebuilt modules must communicate the path to pre-built binary artifacts
    case swiftPrebuiltExternal(SwiftPrebuiltExternalModuleDetails)

    /// Clang modules are built from a module map file.
    case clang(ClangModuleDetails)
  }

  public init(modulePath: TextualVirtualPath,
              sourceFiles: [String]?,
              directDependencies: [ModuleDependencyId]?,
              details: Details) {
    self.modulePath = modulePath
    self.sourceFiles = sourceFiles
    self.directDependencies = directDependencies
    self.details = details
  }
}

extension ModuleInfo.Details: Codable {
  enum CodingKeys: CodingKey {
    case swift
    case swiftPlaceholder
    case swiftPrebuiltExternal
    case clang
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      let details = try container.decode(SwiftModuleDetails.self, forKey: .swift)
      self = .swift(details)
    } catch {
      do {
        let details = try container.decode(SwiftPlaceholderModuleDetails.self,
                                           forKey: .swiftPlaceholder)
        self = .swiftPlaceholder(details)
      } catch {
        do {
          let details = try container.decode(SwiftPrebuiltExternalModuleDetails.self,
                                             forKey: .swiftPrebuiltExternal)
          self = .swiftPrebuiltExternal(details)
        } catch {
          let details = try container.decode(ClangModuleDetails.self, forKey: .clang)
          self = .clang(details)
        }
      }
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
      case .swift(let details):
        try container.encode(details, forKey: .swift)
      case .swiftPlaceholder(let details):
        try container.encode(details, forKey: .swiftPlaceholder)
      case .swiftPrebuiltExternal(let details):
        try container.encode(details, forKey: .swiftPrebuiltExternal)
      case .clang(let details):
        try container.encode(details, forKey: .clang)
    }
  }
}

/// Describes the complete set of dependencies for a Swift module, including
/// all of the Swift and C modules and source files it depends on.
public struct InterModuleDependencyGraph: Codable {
  /// The name of the main module.
  public var mainModuleName: String

  /// The complete set of modules discovered
  public var modules: ModuleInfoMap = [:]

  /// Information about the main module.
  public var mainModule: ModuleInfo { modules[.swift(mainModuleName)]! }
}


// MARK: - Serialization

extension InterModuleDependencyGraph {
  @_spi(Testing) public static func read(from path: VirtualPath, on fileSystem: FileSystem)
  throws -> InterModuleDependencyGraph? {
    guard try fileSystem.exists(path) else {
      return nil
    }
    let contents = try fileSystem.readFileContents(path)
    return try? JSONDecoder().decode(InterModuleDependencyGraph.self, from: Data(contents.contents))
  }
}

extension InterModuleDependencyGraph {
  @_spi(Testing) public func write(to path: VirtualPath, on fileSystem: FileSystem) throws {
    let encoder = JSONEncoder()
    let contents = try encoder.encode(self)
    print("DRIVER: Writing computed dependency graph to: \(path.description)")
    do {
      try fileSystem.writeFileContents(path,
                                       bytes: .init(contents),
                                       atomically: true)
    } catch {
      // FIXME: Artem
      fatalError("Couldn't write inter-module dependency graph")
    }
  }
}
