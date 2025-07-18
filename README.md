# Swift Compiler Driver

Swift's compiler driver is a program that coordinates the compilation of Swift source code into various compiled results: executables, libraries, object files, Swift modules and interfaces, etc. It is the program one invokes from the command line to build Swift code (i.e., `swift` or `swiftc`) and is often invoked on the developer's behalf by a build system such as the [Swift Package Manager](https://github.com/swiftlang/swift-package-manager) or [Swift Build](https://github.com/swiftlang/swift-build).

The `swift-driver` project is the primary implementation of the Swift compiler driver that has replaced the [legacy driver](https://github.com/apple/swift/tree/main/lib/Driver) with a more extensible, maintainable, and robust code base. Core pillars of the project's architecture include:

* A maintainable, robust, and flexible Swift code base
* Library-based architecture that allows better integration with build tools
* Leverage existing Swift build technologies ([SwiftPM](https://github.com/swiftlang/swift-package-manager), [llbuild](https://github.com/apple/swift-llbuild))
* A platform for experimenting with more efficient build models for Swift, including compile servers and unifying build graphs across different driver invocations

## Getting Started

The preferred way to build `swift-driver` is to use the Swift package manager.

On most platforms you can build using:

```
$ swift build
```

However, on Windows, because Swift Package Manager does not differentiate between C/C++ and Swift targets and uses the Swift driver as the linker driver we must link in the Swift runtime into all targets manually:

```cmd
swift build -Xlinker "%SDKROOT%\usr\lib\swift\windows\x86_64\swiftCore.lib"
```

To use a locally-built `swift-driver` in place of the existing Swift driver, create a symbolic link from `swift` and `swiftc` to `swift-driver`:

```
ln -s /path/to/built/swift-driver $SOME_PATH/swift
ln -s /path/to/built/swift-driver $SOME_PATH/swiftc
```

Swift packages can be built with the new Swift driver by overriding `SWIFT_EXEC` to refer to the `swiftc` symbolic link created above and `SWIFT_DRIVER_SWIFT_FRONTEND_EXEC` to refer to the original `swift-frontend`, e.g.

```
SWIFT_EXEC=$SOME_PATH/swiftc SWIFT_DRIVER_SWIFT_FRONTEND_EXEC=$TOOLCHAIN_PATH/bin/swift-frontend swift build
```

Similarly, one can use the Swift driver within Xcode by adding a custom build setting (usually at the project level) named `SWIFT_EXEC` that refers to `$SOME_PATH/swiftc`.

## Building with CMake

`swift-driver` can also be built with CMake, which is suggested for environments where the Swift Package Manager is not yet available. Doing so requires several dependencies to be built first, all with CMake:

* (Non-Apple platforms only) [swift-corelibs-foundation](https://github.com/apple/swift-corelibs-foundation)
* [llbuild](https://github.com/apple/swift-llbuild) configure CMake with `-DLLBUILD_SUPPORT_BINDINGS="Swift"` and `-DCMAKE_OSX_ARCHITECTURES=x86_64` (If building on Intel) when building
  ```
  cmake -B <llbuild-build-dir> -G Ninja <llbuild-source-dir> -DLLBUILD_SUPPORT_BINDINGS="Swift" -DCMAKE_OSX_ARCHITECTURES=x86_64
  ```
* [swift-argument-parser](https://github.com/apple/swift-argument-parser)

Once those dependencies have built, build `swift-driver` itself:
```
cmake -B <swift-driver-build-dir> -G Ninja <swift-driver-source-dir> -DTSC_DIR=<swift-tools-support-core-build-dir>/cmake/modules -DLLBuild_DIR=<llbuild-build-dir>/cmake/modules -DArgumentParser_DIR=<swift-argument-parser-build-dir>
cmake --build <swift-driver-build-dir>
```

## Developing `swift-driver`

Swift compiler driver is constantly evolving and improving, and there are numerous places for anyone with an interest to contribute! This section covers testing, and miscellaneous development tips and tricks.

### Driver Documentation

For a conceptual overview of the driver, see [The Swift Driver, Compilation Model, and Command-Line Experience](https://github.com/apple/swift/blob/main/docs/Driver.md). To learn more about the internals, see [Driver Design & Internals](https://github.com/apple/swift/blob/main/docs/DriverInternals.md) and [Parseable Driver Output](https://github.com/apple/swift/blob/main/docs/DriverParseableOutput.md).

### Testing

Test using command-line SwiftPM or Xcode.

```
$ swift test --parallel
```

#### Testing against `swift` compiler trunk
`swift-driver` Continuous Integration runs against the most recent Trunk Development snapshot published at [swift.org/download](https://swift.org/download/).

When developing patches that have complex interactions with the underlying `swift` compiler frontend, it may be prudent to ensure that `swift-driver` tests also pass against the current tip-of-trunk `swift`. To do so, create an empty pull request against [github.com/apple/swift](https://github.com/apple/swift) and perform cross-repository testing against your `swift-driver` pull request #, for example:
```
Using:
apple/swift-driver#208
@swift-ci smoke test
```
@swift-ci cross-repository testing facilities are described [here](https://github.com/apple/swift/blob/main/docs/ContinuousIntegration.md#cross-repository-testing).

### Testing in Xcode with custom toolchain
After the toolchain is installed, Xcode needs to be told to use it. This can mean two things, building the driver with the toolchain and telling the driver to use the toolchain when running.

Building with the toolchain is easy, set the toolchain in Xcode: Menu Bar > Xcode > Toolchains > select your toolchain

Running the driver requires setting the TOOLCHAINS environment variable. This tells xcrun which toolchain to use (on darwin xcrun is used to find tools). This variable is the name of the toolchain and not the path (ex: `Swift Development Snapshot`). Important note: xcrun lookup is lower priority than the `SWIFT_EXEC_*_EXEC` family of environment variables, the tools directory, and any tools in the same directory as the driver (This includes a driver installed in a toolchain). Even though `TOOLCHAINS` is not highest priority it's a convenient way to run the xctest suite using a custom toolchain.

#### Preparing a Linux docker for debug

When developing on macOS without quick access to a Linux machine, using a Linux Docker is often helpful when debugging.

To get a docker up and running to the following:
- Install Docker for Mac.
- Get the newest swift docker image `docker pull swift`.
- Run the following command to start a docker
```
$ docker run -v /path/to/swift-driver:/home/swift-driver \
  --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined -it swift:latest bash
```
- Install dependencies by running
```
$ apt-get update
$ apt-get install libsqlite3-dev
$ apt-get install libncurses-dev
```
- You can now go to `/home/swift-driver` and run `swift test --parallel` to run your tests.


### Rebuilding `Options.swift`

`Options.swift`, which contains the complete set of options that can be parsed by the driver, is automatically generated from the [option tables in the Swift compiler](https://github.com/apple/swift/tree/main/include/swift/Option). If you need to regenerate `Options.swift`, you will need to [build the Swift compiler](https://github.com/apple/swift#building-swift) and then build `makeOptions` program with a `-I` that allows the generated `Options.inc` to
be found, e.g.:

```
$ swift build -Xcc -I/path/to/build/Ninja-Release/swift-.../include -Xcc -I/path/to/build/Ninja-Release/llvm-.../include -Xcc -I/path/to/source/llvm-project/llvm/include --product makeOptions
```

Then, run `makeOptions` and redirect the output to overwrite `Options.swift`:

```
$ .build/path/to/makeOptions > Sources/SwiftOptions/Options.swift
```

### Development Plan

The development plan below covers a number of tasks that can improve the Swift driver---from code cleanups, to improving testing, implementing missing features, and integrating with existing systems.

* Code and documentation quality
  * Search for `FIXME:` or `TODO:`: there are lots of little things to improve!
  * Improve documentation of how to incorporate the driver into your own builds
  * Add useful descriptions to any `Error` thrown within the library
* Option parsing
  * Look for complete "coverage" of the options in `Options.swift`. Is every option there checked somewhere in the driver?
  * Find a better way to describe aliases for options. Can they be of some other type `OptionAlias` so we can't make the mistake of (e.g.) asking for an alias option when we're translating options?
  * Diagnose unused options on the command line
  * Typo correction for misspelled option names
  * Find a better way than `makeOptions.cpp` to translate the command-line options from [Swift's repository](https://github.com/apple/swift/tree/main/include/swift/Option) into `Options.swift`.

### Build all Swift interfaces from an SDK
Based on libSwiftDriver, `swift-build-sdk-interfaces`  is a tool to batch build all Swift textual interfaces (`.swiftinterface`) from an SDK into binary modules (`.swiftmodule`). As an example, the following command finds all Swift textual interface from the MacOSX SDK, builds all of them into binary modules, and outputs module-specific error logs into the given directory.

```
$ $SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk SWIFT_EXEC=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc swift-build-sdk-interfaces -o /tmp/outputs -v -log-path /tmp/logs`
```

* *SDKROOT*: an env var to specify the SDK to work on
* *SWIFT_EXEC*: teach `swift-build-sdk-interfaces` about where to find the Swift compiler to use
* *-O*: the output directory for all binary modules built from textual interfaces
* *-log-path*: where to dump log files when fatal error happens


## Contributing to swift-driver

Contributions to swift-driver are welcomed and encouraged! Please see the [Contributing to Swift guide](https://swift.org/contributing/).

Before submitting the pull request, please make sure you have [tested your changes](https://github.com/apple/swift/blob/main/docs/ContinuousIntegration.md) and that they follow the Swift project [guidelines for contributing code](https://swift.org/contributing/#contributing-code).

To be a truly great community, [Swift.org](https://swift.org/) needs to welcome developers from all walks of life, with different backgrounds, and with a wide range of experience. A diverse and friendly community will have more great ideas, more unique perspectives, and produce more great code. We will work diligently to make the Swift community welcoming to everyone.

To give clarity of what is expected of our members, Swift has adopted the code of conduct defined by the Contributor Covenant. This document is used across many open source communities, and we think it articulates our values well. For more, see the [Code of Conduct](https://swift.org/code-of-conduct/).
