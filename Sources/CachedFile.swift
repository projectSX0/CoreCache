
//  Copyright (c) 2016, Yuji
//  All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//
//  1. Redistributions of source code must retain the above copyright notice, this
//  list of conditions and the following disclaimer.
//  2. Redistributions in binary form must reproduce the above copyright notice,
//  this list of conditions and the following disclaimer in the documentation
//  and/or other materials provided with the distribution.
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
//  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
//  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//  DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
//  ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
//  (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
//  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
//  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
//  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
//  The views and conclusions contained in the software and documentation are those
//  of the authors and should not be interpreted as representing official policies,
//  either expressed or implied, of the FreeBSD Project.
//
//  Created by yuuji on 9/27/16.
//  Copyright © 2016 yuuji. All rights reserved.
//

import CKit
import Dispatch
import struct Foundation.Data

#if os(OSX) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif

internal struct CachedFile: Cache {
    internal var file: File
    internal var timer: Timer?
}

extension CachedFile {
    internal final class File {
        
        internal var source: DispatchSourceProtocol?
        
        internal var path: String
        internal var policy: CachePolicy
        
        internal var lastfd: Int32
        internal var laststat: FileStatus
        
        internal var updatedDate: time_t
        
        internal var mappedData: Data?
        internal var swap: Data?
        
        internal init(path: String, policy: CachePolicy, fd: Int32, stat: FileStatus, updated: time_t) {
            self.path = path
            self.policy = policy
            self.lastfd = fd
            self.laststat = stat
            self.updatedDate = updated
        }
        
        #if !os(Linux)
        internal func setSource(to fd: Int32) {
            self.source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.link, .write])
            self.source!.setEventHandler(qos: DispatchQoS.default, flags: [], handler: {
                do {
                    try self.update()
                } catch {}
            })
            self.source!.resume()
        }
        
        internal func resetSource(to fd: Int32) {
            if self.source != nil {
                self.source!.cancel()
                self.setSource(to: fd)
            }
        }
        #endif
        
        internal func update() throws {
            if let stat = try? FileStatus(fd: self.lastfd) {
                if stat == self.laststat {
                    return
                }
            }
            
            let newfd = open(path, O_RDWR)
            
            if newfd == -1 {
                throw CachedFile.Error.open(String.lastErrnoString)
            }
            
            close(self.lastfd)
            
            self.lastfd = newfd
            self.laststat = try FileStatus(fd: lastfd)
            
            #if !os(Linux)
            resetSource(to: newfd)
            #endif
            
            if case .noReserve = policy {} else {
                
                let ptr = mmap(nil, laststat.size, PROT_READ | PROT_WRITE | PROT_EXEC , MAP_FILE | MAP_PRIVATE, lastfd, 0)
                
                if ptr?.numerialValue == -1 {
                    perror("mmap")
                } else {
                    mappedData = Data(bytesNoCopy: UnsafeMutableRawPointer(ptr)!, count: laststat.size, deallocator: .unmap)
                }
            }
            
            self.updatedDate = time(nil)
        }
        
    }
}

extension CachedFile {
    internal var path: String {
        return self.file.path
    }
    
    internal var updatedDate: time_t {
        return self.file.updatedDate
    }
}

internal extension CachedFile {
    
    internal func read() -> Data? {
        switch self.file.policy {
        case .oldCopy:
            let reserved = self.file.mappedData
            try? self.file.update()
            return reserved
        case .up2Date:
            #if os(Linux)
            fallthrough
            #else
            break
            #endif
        case .lazyUp2Date:
            try? self.file.update()
            fallthrough
        default:
            break
        }
        return self.file.mappedData
    }
    
    internal var currentFileDescriptor: Int32 {
        return self.file.lastfd
    }
    
    internal func update() {
        try? self.file.update()
    }
    
    internal init(path: String, policy: CachePolicy) throws {
        let fd = open(path, O_RDWR)
        let laststat = try FileStatus(fd: fd)
        let updatedDate = time(nil)
        
        self.file = File(path: path,
                         policy: policy,
                         fd: fd,
                         stat: laststat,
                         updated: updatedDate)
        
        switch policy {
        case .up2Date:
            #if !os(Linux)
            self.file.setSource(to: fd)
            #endif
            break
        default:
            break
        }
        
        if case .noReserve = policy {} else {
            let ptr = mmap(nil, laststat.size, PROT_READ | PROT_WRITE , MAP_FILE | MAP_PRIVATE, self.file.lastfd, 0)
            if ptr?.numerialValue == -1 {
                perror("mmap")
            } else {
                self.file.mappedData = Data(bytesNoCopy: UnsafeMutableRawPointer(ptr)!, count: laststat.size, deallocator: .unmap)
            }
        }
    }
}

