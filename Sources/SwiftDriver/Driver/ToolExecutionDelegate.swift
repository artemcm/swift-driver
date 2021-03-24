//===--------------- ToolExecutionDelegate.swift - Tool Execution Delegate ===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import TSCBasic

#if canImport(Darwin)
import Darwin.C
#elseif os(Windows)
import ucrt
import WinSDK
#elseif canImport(Glibc)
import Glibc
#else
#error("Missing libc or equivalent")
#endif

/// Delegate for printing execution information on the command-line.
final class ToolExecutionDelegate: JobExecutionDelegate {
  public enum Mode {
    case verbose
    case parsableOutput
    case regular
  }

  public let mode: Mode
  public let buildRecordInfo: BuildRecordInfo?
  public let incrementalCompilationState: IncrementalCompilationState?
  public let showJobLifecycle: Bool
  public let diagnosticEngine: DiagnosticsEngine

  public var anyJobHadAbnormalExit: Bool = false

  init(mode: ToolExecutionDelegate.Mode,
       buildRecordInfo: BuildRecordInfo?,
       incrementalCompilationState: IncrementalCompilationState?,
       showJobLifecycle: Bool,
       diagnosticEngine: DiagnosticsEngine) {
    self.mode = mode
    self.buildRecordInfo = buildRecordInfo
    self.incrementalCompilationState = incrementalCompilationState
    self.showJobLifecycle = showJobLifecycle
    self.diagnosticEngine = diagnosticEngine
  }

  public func jobStarted(job: Job, arguments: [String], pid: Int) {
    if showJobLifecycle {
      diagnosticEngine.emit(.remark_job_lifecycle("Starting", job))
    }
    switch mode {
    case .regular:
      break
    case .verbose:
      stdoutStream <<< arguments.map { $0.spm_shellEscaped() }.joined(separator: " ") <<< "\n"
      stdoutStream.flush()
    case .parsableOutput:
      let beganMessages = constructJobBeganMessages(job: job, arguments: arguments, pid: pid)
      for beganMessage in beganMessages {
        let message = ParsableMessage(name: job.kind.rawValue, kind: .began(beganMessage))
        emit(message)
      }
    }
  }

  public func constructJobBeganMessages(job: Job, arguments: [String], pid: Int) -> [BeganMessage] {
    let result : [BeganMessage]
    // Batched compile jobs need to be broken up into multiple messages, one per constituent.
    if job.kind == .compile {
      if job.primaryInputs.count == 1 {
        result = [constructSingleBeganMessage(inputs: job.displayInputs,
                                              outputs: job.outputs,
                                              arguments: arguments,
                                              pid: pid)]
      } else {
        result = constructBatchCompileBeginMessages(job: job, arguments: arguments, pid: pid)
      }
    } else {
      result = [constructSingleBeganMessage(inputs: job.displayInputs,
                                            outputs: job.outputs,
                                            arguments: arguments,
                                            pid: pid)]
    }

    return result
  }

  public func constructBatchCompileBeginMessages(job: Job, arguments: [String], pid: Int)
  -> [BeganMessage] {
    precondition(job.kind == .compile && job.primaryInputs.count > 1)
    let result = job.primaryInputs.map { input -> BeganMessage in
      constructSingleBeganMessage(inputs: [input],
                                  outputs: job.getCompileInputOutputs(for: input) ?? [],
                                  arguments: Self.filterPrimaryInputArgument(in: arguments,
                                                                             input: input),
                                  pid: pid)
    }
    return result
  }

  public func constructSingleBeganMessage(inputs: [TypedVirtualPath],
                                          outputs: [TypedVirtualPath],
                                          arguments: [String],
                                          pid: Int) -> BeganMessage {

    let outputs: [BeganMessage.Output] = outputs.map {
      .init(path: $0.file.name, type: $0.type.description)
    }

    return BeganMessage(
      pid: pid,
      inputs: inputs.map{ $0.file.name },
      outputs: outputs,
      commandExecutable: arguments[0],
      commandArguments: arguments[1...].map { String($0) }
    )
  }


  private static func filterPrimaryInputArgument(in arguments: [String],
                                                 input: TypedVirtualPath) -> [String] {
    // We must have only one `-primary-file` option specified, the one that corresponds
    // to the primary file whose job this message is faking.
    return arguments.enumerated().compactMap() { index, element -> String? in
      if element == "-primary-file" {
        assert(arguments.count > index + 1)
        return arguments[index + 1].hasSuffix(input.file.basename) ? element : nil
      }
      return element
    }
  }

  public func jobFinished(job: Job, result: ProcessResult, pid: Int) {
     if showJobLifecycle {
      diagnosticEngine.emit(.remark_job_lifecycle("Finished", job))
    }

    buildRecordInfo?.jobFinished(job: job, result: result)

    // FIXME: Currently, TSCBasic.Process uses NSProcess on Windows and discards
    // the bits of the exit code used to differentiate between normal and abnormal
    // termination.
    #if !os(Windows)
    if case .signalled = result.exitStatus {
      anyJobHadAbnormalExit = true
    }
    #endif

    switch mode {
    case .regular, .verbose:
      let output = (try? result.utf8Output() + result.utf8stderrOutput()) ?? ""
      if !output.isEmpty {
        Driver.stdErrQueue.sync {
          stderrStream <<< output
          stderrStream.flush()
        }
      }

    case .parsableOutput:
      let output = (try? result.utf8Output() + result.utf8stderrOutput()).flatMap { $0.isEmpty ? nil : $0 }
      let message: ParsableMessage

      switch result.exitStatus {
      case .terminated(let code):
        let finishedMessage = FinishedMessage(exitStatus: Int(code), pid: pid, output: output)
        message = ParsableMessage(name: job.kind.rawValue, kind: .finished(finishedMessage))

#if !os(Windows)
      case .signalled(let signal):
        let errorMessage = strsignal(signal).map { String(cString: $0) } ?? ""
        let signalledMessage = SignalledMessage(pid: pid, output: output, errorMessage: errorMessage, signal: Int(signal))
        message = ParsableMessage(name: job.kind.rawValue, kind: .signalled(signalledMessage))
#endif
      }
      emit(message)
    }
  }

  public func jobSkipped(job: Job) {
    if showJobLifecycle {
      diagnosticEngine.emit(.remark_job_lifecycle("Skipped", job))
    }
    switch mode {
    case .regular, .verbose:
      break
    case .parsableOutput:
      let skippedMessage = SkippedMessage(inputs: job.displayInputs.map{ $0.file.name })
      let message = ParsableMessage(name: job.kind.rawValue, kind: .skipped(skippedMessage))
      emit(message)
    }
  }

  private func emit(_ message: ParsableMessage) {
    // FIXME: Do we need to do error handling here? Can this even fail?
    guard let json = try? message.toJSON() else { return }
    Driver.stdErrQueue.sync {
      stderrStream <<< json.count <<< "\n"
      stderrStream <<< String(data: json, encoding: .utf8)! <<< "\n"
      stderrStream.flush()
    }
  }
}

fileprivate extension Diagnostic.Message {
  static func remark_job_lifecycle(_ what: String, _ job: Job
  ) -> Diagnostic.Message {
    .remark("\(what) \(job.descriptionForLifecycle)")
  }
}
