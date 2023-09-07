//
// Copyright © 2023 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation

class UTMQemuSystem: UTMProcess, QEMULauncher {
    public var rendererBackend: UTMQEMURendererBackend
    @objc public var launcherDelegate: QEMULauncherDelegate
    @objc public var logging: QEMULogging
    public var hasDebugLog: Bool
    public var architecture: String
    public var mutableEnvironemnt: Dictionary<String, String>
    public var _qemu_init: @convention(c)(Int32, UnsafeMutablePointer<UnsafePointer<Int8>>, UnsafeMutablePointer<UnsafePointer<Int8>>) -> Int32
    public var _qemu_main_loop: @convention(c)() -> Void
    public var _qemu_cleanup: @convention(c)() -> Void
    public var resources: [URL]
    public var remoteBookmarks: Dictionary<URL, Data>

    public init?(arguments: [String], architecture: String) {
        super.init(arguments: arguments)
        self.entry = UTMQemuSystem.startQemu
        self.architecture = architecture
    }

    public override func didLoadDylib(_ handle: UnsafeMutableRawPointer) -> Bool {
        let initPtr = dlsym(handle, "qemu_init")
        let mainLoopPtr = dlsym(handle, "qemu_main_loop")
        let cleanupPtr = dlsym(handle, "qemu_cleanup")

        _qemu_init = unsafeBitCast(initPtr, to: (@convention(c)(Int32, UnsafeMutablePointer<UnsafePointer<Int8>>, UnsafeMutablePointer<UnsafePointer<Int8>>) -> Int32).self)
        _qemu_main_loop = unsafeBitCast(mainLoopPtr, to: (@convention(c)() -> Void).self)
        _qemu_cleanup = unsafeBitCast(cleanupPtr, to: (@convention(c)() -> Void).self)

        // In Swift, UnsafeMutableRawPointer will always have a value
        return true
    }

    public static func startQemu(process: UTMProcess, argc: Int32, argv: UnsafeMutablePointer<UnsafePointer<Int8>>, envp: UnsafeMutablePointer<UnsafePointer<Int8>>) -> Int32 {
        var process = process as! UTMQemuSystem
        var ret: Int32 = process._qemu_init(argc, argv, envp)
        if (ret != 0) {
            return ret;
        }
        process._qemu_main_loop()
        process._qemu_cleanup()
        return 0
    }
    
    public func setRendererBackend(rendererBackend: UTMQEMURendererBackend) {
        self.rendererBackend = rendererBackend
        switch rendererBackend {
        case .kQEMURendererBackendAngleMetal:
            mutableEnvironemnt["ANGLE_DEFAULT_PLATFORM"] = "metal"
        default:
            mutableEnvironemnt.removeValue(forKey: "ANGLE_DEFAULT_PLATFORM")
            break
        }
    }

    public func standardOutput() -> Pipe {
        return logging.standardOutput
    }

    public func standardError() -> Pipe {
        return logging.standardError
    }
    
    public func environment() -> Dictionary<String, String> {
        return mutableEnvironemnt
    }

    public func setLogging(logging: QEMULogging) {
        self.logging = logging
        logging.writeLine(String(format: "Launching: qemu-system-%@%@\n", architecture, arguments))
    }
    
    public func startHasDebugLog(hasDebugLog: Bool) {
        self.hasDebugLog = hasDebugLog
        if hasDebugLog {
            mutableEnvironemnt["G_MESSAGES_DEBUG"] = "all"
        } else {
            mutableEnvironemnt.removeValue(forKey: "G_MESSAGES_DEBUG")
        }
    }

    public func startQemuWithCompletion(completion: @escaping (_ error: Error?) -> Void) {
        var group: DispatchGroup = DispatchGroup()
        for resourceURL in resources {
            var bookmark: Data? = remoteBookmarks[resourceURL]
            var securityScoped = true
            if bookmark == nil {
                bookmark = resourceURL.bookmarkData()
                securityScoped = false
            }
            if let bookmark = bookmark {
                group.enter()
                accessData(withBookmark: bookmark, securityScoped: securityScoped, completion: { success, bookmark, path in
                    if !success {
                        UTMLoggingSwift.log("Access QEMU bookmark failed for: %@", path!)
                    }
                    group.leave()
                })
            }
        }
        group.wait()
        var name = String(format: "qemu-%@-softmmu", architecture)
        startProcess(name: name, completion: completion)
    }

    @objc public func stopQemu() {
        stopProcess()
    }
    
    public override func processHasExited(exitCode: Int, message: String?) {
        launcherDelegate.qemuLauncher(self, didExitWithExitCode: exitCode, message: message)
    }
}

/// Specify the backend renderer for this VM
enum UTMQEMURendererBackend: Int {
    case kQEMURendererBackendDefault = 0
    case kQEMURendererBackendAngleGL = 1
    case kQEMURendererBackendAngleMetal = 2
    case kQEMURendererBackendMax = 3
}

/// Specify the sound backend for this VM
enum UTMQEMUSoundBackend: Int {
    case kQEMUSoundBackendDefault = 0
    case kQEMUSoundBackendSPICE = 1
    case kQEMUSoundBackendCoreAudio = 2
    case kQEMUSoundBackendMax = 3
}
